defmodule Harness.Insights.PostgresTest do
  use Harness.DataCase, async: false
  use Harness.Test.InsightsEvidenceContract, integration: true

  alias Harness.Insights
  alias Harness.Insights.Document
  alias Harness.Insights.Store
  alias Harness.Insights.Tick
  alias Harness.Insights.Worker
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.ResultStoreContract

  @moduletag :integration

  setup do
    old_models = Application.get_env(:harness, :agent_model)
    Application.put_env(:harness, :agent_model, codex: "gpt-6-astra")

    on_exit(fn ->
      if old_models,
        do: Application.put_env(:harness, :agent_model, old_models),
        else: Application.delete_env(:harness, :agent_model)
    end)

    old_repo = Application.get_env(:harness, :repo_enabled)
    old_store = Application.get_env(:harness, :result_store)

    on_exit(fn ->
      Application.put_env(:harness, :repo_enabled, old_repo)
      Application.put_env(:harness, :result_store, old_store)
      Application.delete_env(:harness, :insights_witness)
      Application.delete_env(:harness, :insights_test_owner)
      Application.delete_env(:harness, :insights_test_response)
      ProjectRegistry.reset()
    end)

    Application.put_env(:harness, :repo_enabled, true)
    Application.put_env(:harness, :result_store, Harness.ResultStore.Postgres)
    Application.put_env(:harness, :insights_witness, Harness.Test.InsightsWitness)
    Application.put_env(:harness, :insights_test_owner, self())
    ProjectRegistry.reset()
    :ok = ProjectRegistry.register(ProjectFixture.from_repo("/tmp/insights-pg", name: "insights-pg"))
    Repo.delete_all(Document)

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

  test "a rejected final database write fails the pass and leaves the checkpoint intact" do
    assert :ok = Insights.observe("before-write-failure")
    checkpoint = Store.get("progress")
    :ok = ResultStore.record_run(record("write-failure"))

    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_insights_progress() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.id = 'progress' THEN RAISE EXCEPTION 'injected final publication failure'; END IF;
      RETURN NEW;
    END $$
    """)

    Repo.query!(
      "CREATE TRIGGER reject_insights_progress BEFORE INSERT OR UPDATE ON run_insights_documents FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_insights_progress()"
    )

    assert {:error, _} = Insights.observe("write-failure")
    assert Store.get("progress") == checkpoint
    assert Store.get("pass/write-failure")["state"] == "failed"
    refute Store.get("pass/write-failure")["committed"]
    assert Store.get("seen/record/write-failure") == nil
    assert Insights.findings()["items"] == []
  end

  test "discarded retry groups do not enqueue every minute with Daily selected" do
    start_supervised!({Oban, name: Harness.Oban, repo: Repo, testing: :manual, queues: false, plugins: false})
    assert :ok = Insights.configure(Map.put(Insights.settings(), "cadence_minutes", 1440))
    :ok = ResultStore.record_run(record("daily-pg"))
    Application.put_env(:harness, :insights_test_response, {:error, :provider_unavailable})
    assert {:ok, job_id} = Insights.observe_now()
    job = Repo.get!(Oban.Job, job_id)
    for _ <- 1..3, do: assert({:error, :provider_unavailable} = Worker.perform(job))
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job_id), set: [state: "discarded"])
    for _ <- 1..3, do: assert(:ok = Tick.perform(%Oban.Job{}))
    assert Repo.aggregate(from(j in Oban.Job, where: j.worker == "Harness.Insights.Worker"), :count) == 1
    assert Store.get("progress") == nil
  end

  @tag timeout: 300_000
  test "live configured witness publishes and revises Postgres observations from collected run evidence" do
    Application.delete_env(:harness, :insights_witness)
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
           "Live observer requires `codex login` or export OPENAI_API_KEY='your-key' from https://platform.openai.com/api-keys."

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
      ".harness/insights-codex-postgres.json",
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

  defp evidence_record(options) do
    ResultStoreContract.log_record(
      Keyword.merge(
        [
          project_name: "insights-pg",
          run_id: "review-run",
          agent_output: "done",
          reviewer_output: "approved",
          started_at: DateTime.utc_now()
        ],
        options
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
