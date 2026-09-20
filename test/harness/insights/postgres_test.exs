defmodule Harness.Insights.PostgresTest do
  use Harness.DataCase, async: false

  alias Harness.Insights
  alias Harness.Insights.Document
  alias Harness.Insights.Store
  alias Harness.Insights.Tick
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.ResultStoreContract

  @moduletag :integration

  setup do
    old_repo = Application.get_env(:harness, :repo_enabled)
    old_store = Application.get_env(:harness, :result_store)
    Application.put_env(:harness, :repo_enabled, true)
    Application.put_env(:harness, :result_store, Harness.ResultStore.Postgres)
    Application.put_env(:harness, :insights_witness, Harness.Test.InsightsWitness)
    Application.put_env(:harness, :insights_test_owner, self())
    ProjectRegistry.reset()
    :ok = ProjectRegistry.register(ProjectFixture.from_repo("/tmp/insights-pg", name: "insights-pg"))
    Repo.delete_all(Document)

    on_exit(fn ->
      Application.put_env(:harness, :repo_enabled, old_repo)
      Application.put_env(:harness, :result_store, old_store)
      Application.delete_env(:harness, :insights_witness)
      Application.delete_env(:harness, :insights_test_owner)
      Application.delete_env(:harness, :insights_test_response)
      ProjectRegistry.reset()
    end)

    :ok = Insights.configure(Map.put(Insights.settings(), "enabled", true))
    :ok
  end

  test "database retains findings, revisions, citations and checkpoint without local state" do
    record = record("pg-a")
    :ok = ResultStore.record_run(record)
    assert :ok = Insights.observe("pg-pass")
    [finding] = Insights.findings()["items"]
    checkpoint = Insights.status()["progress"]
    assert Repo.get!(Document, "progress").data == checkpoint
    assert Repo.get!(Document, "finding/" <> finding["id"]).data == finding
    Harness.SettingsStore.reset_cache()
    assert Insights.status()["progress"] == checkpoint
    assert :ok = Insights.observe("pg-pass")
    assert Enum.count(Insights.history(finding["id"])["revisions"]) == 1

    Repo.update_all(from(r in Harness.ResultStore.Schema.RunRecord, where: r.run_id == "pg-a"),
      set: [agent_output: nil, reviewer_output: nil, cold_check: %{"passed" => false}]
    )

    assert :ok = Insights.observe("pg-late")
    assert Enum.count(Insights.history(finding["id"])["revisions"]) == 2
    assert Insights.status()["state"] == "partial"
    assert hd(Insights.history(finding["id"])["revisions"])["citations"] != []
  end

  test "bounded durable pages consume backlog and revisit late changes behind the cursor" do
    for n <- 1..15, do: ResultStore.record_run(record("pg-#{String.pad_leading(to_string(n), 2, "0")}"))
    Application.put_env(:harness, :insights_test_response, {:ok, %{"findings" => []}})
    assert :ok = Insights.observe("page-1")
    assert Insights.status()["last_pass"]["pending"]
    assert Insights.status()["progress"]["cursor"] == "pg-12"
    assert :ok = Insights.observe("page-2")
    assert Insights.status()["progress"]["cursor"] == ""
    assert Insights.status()["progress"]["scanned"] == 15
    assert :ok = ResultStore.mark_landed("pg-01", "landed-sha")
    assert :ok = Insights.observe("page-3")
    assert Insights.status()["last_pass"]["changed_runs"] == 1
  end

  test "failed publication does not advance database progress and retry uses same id" do
    :ok = ResultStore.record_run(record("pg-failure"))
    Application.put_env(:harness, :insights_test_response, {:error, :provider_unavailable})
    assert {:error, :provider_unavailable} = Insights.observe("retry")
    assert Store.get("progress") == nil
    assert Store.get("pass/retry")["state"] == "failed"
    Application.put_env(:harness, :insights_test_response, {:ok, %{"findings" => []}})
    assert :ok = Insights.observe("retry")
    assert Store.get("pass/retry")["committed"]
    assert Enum.count(Store.list("pass")) == 1
  end

  test "Oban deduplicates scheduled passes and retains the original publication id" do
    start_supervised!({Oban, name: Harness.Oban, repo: Repo, testing: :manual, queues: false, plugins: false})
    assert {:ok, first} = Insights.observe_now()
    assert {:ok, ^first} = Insights.observe_now()

    assert [%Oban.Job{args: %{"pass_id" => pass_id}}] =
             Repo.all(from j in Oban.Job, where: j.worker == "Harness.Insights.Worker")

    assert is_binary(pass_id)
    assert :ok = Tick.perform(%Oban.Job{})
    assert Repo.aggregate(from(j in Oban.Job, where: j.worker == "Harness.Insights.Worker"), :count) == 1
    assert Keyword.fetch!(Harness.Oban.oban_opts()[:queues], :insights) == 1
  end

  test "a different database session cannot overlap an observation pass" do
    config = Keyword.take(Repo.config(), [:hostname, :socket_dir, :port, :database, :username, :password])
    connection = start_supervised!({Postgrex, config})
    assert {:ok, _} = Postgrex.query(connection, "SELECT pg_advisory_lock(443, 1)", [])
    assert {:error, :already_observing} = Insights.observe("overlap")
    assert Store.get("pass/overlap") == nil
    assert {:ok, _} = Postgrex.query(connection, "SELECT pg_advisory_unlock(443, 1)", [])
    assert :ok = Insights.observe("overlap")
  end

  @tag :live_agent
  @tag timeout: 300_000
  test "live configured witness publishes and revises Postgres observations from collected run evidence" do
    Application.put_env(:harness, :insights_witness, Harness.Insights.Witness)
    :ok = ProjectRegistry.register(ProjectFixture.from_repo("/tmp/insights-pg-other", name: "insights-other"))

    first = %{
      record("live-pg-a")
      | reviewer_diff_size: 18,
        review_report: "Reviewer fixed the missing empty-input validation and added a regression test."
    }

    second = %{
      record("live-pg-b")
      | project_name: "insights-other",
        reviewer_diff_size: 21,
        review_report: "Reviewer again fixed the missing empty-input validation and added a regression test."
    }

    :ok = ResultStore.record_run(first)
    :ok = ResultStore.record_run(second)

    assert :ok = Insights.observe("live-pg-first"),
           "Live observer requires `claude auth login` or export ANTHROPIC_API_KEY='your-key' from https://console.anthropic.com/settings/keys."

    assert [_ | _] = findings = Insights.findings()["items"]
    ids = Enum.map(findings, & &1["id"])

    :ok =
      ResultStore.record_run(%{
        first
        | cold_check: %{
            "passed" => false,
            "report" =>
              "A later check still fails on empty input after merge. The earlier reviewer repair did not resolve the recurrence."
          }
      })

    assert :ok = Insights.observe("live-pg-later")
    assert Enum.any?(ids, &(Enum.count(Insights.history(&1)["revisions"]) > 1))
    File.mkdir_p!(".harness")

    File.write!(
      ".harness/insights-live-postgres.json",
      Jason.encode!(
        %{
          first_pass: Store.get("pass/live-pg-first"),
          later_pass: Store.get("pass/live-pg-later"),
          histories: Enum.map(ids, &Insights.history/1)
        },
        pretty: true
      )
    )
  end

  defp record(id),
    do:
      ResultStoreContract.log_record(
        run_id: id,
        project_name: "insights-pg",
        agent_output: "implementation done",
        reviewer_output: "reviewer repaired missing validation"
      )
end
