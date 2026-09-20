defmodule Harness.Insights.EvidenceRegressionTest do
  use ExUnit.Case, async: false
  use Harness.Test.InsightsEvidenceContract

  alias Harness.Insights
  alias Harness.Insights.Evidence
  alias Harness.Insights.Store
  alias Harness.ResultStore
  alias Harness.ResultStore.Memory
  alias Harness.Test.InsightsScriptedWitness
  alias Harness.Test.InsightsWitness

  setup do
    old_models = Application.get_env(:harness, :agent_model)
    Application.put_env(:harness, :agent_model, codex: "gpt-6-astra")

    on_exit(fn ->
      if old_models,
        do: Application.put_env(:harness, :agent_model, old_models),
        else: Application.delete_env(:harness, :agent_model)
    end)

    old = Application.get_env(:harness, :result_store)

    on_exit(fn ->
      Application.put_env(:harness, :result_store, old)

      for key <- [:insights_witness, :insights_test_owner, :insights_test_response],
          do: Application.delete_env(:harness, key)

      :ets.delete_all_objects(Store)
      Harness.ProjectRegistry.reset()
    end)

    Application.put_env(:harness, :result_store, {Memory, scope: __MODULE__})
    Memory.reset(scope: __MODULE__)
    Store.get("settings")
    :ets.delete_all_objects(Store)
    Harness.ProjectRegistry.reset()
    :ok = Harness.ProjectRegistry.register(Harness.ProjectFixture.from_repo("/tmp/insights-review", name: "review"))
    Application.put_env(:harness, :insights_witness, InsightsWitness)
    Application.put_env(:harness, :insights_test_owner, self())
    Application.put_env(:harness, :insights_test_response, {:ok, %{"findings" => []}})
    :ok = Insights.configure(Map.put(Insights.settings(), "enabled", true))
    :ok
  end

  defp record(opts),
    do:
      Harness.ResultStoreContract.log_record(
        Keyword.merge(
          [
            project_name: "review",
            run_id: "review-run",
            agent_output: "done",
            reviewer_output: "approved",
            started_at: DateTime.utc_now()
          ],
          opts
        )
      )

  test "AI can retrieve older finding pages and source tails before checkpointing" do
    :ok =
      Store.put_many([
        {"finding/original", "finding",
         %{"id" => "original", "title" => "Recurring", "projects" => ["review"], "runs" => [], "citations" => []}}
      ])

    :ok =
      Store.put_many(
        for n <- 1..21,
            do:
              {"finding/later-#{n}", "finding",
               %{"id" => "later-#{n}", "title" => "Unrelated", "projects" => [], "runs" => [], "citations" => []}}
      )

    :ok = ResultStore.record_run(record(review_report: String.duplicate("x", 12_000) <> "TAIL_EVIDENCE"))
    Application.put_env(:harness, :insights_witness, InsightsScriptedWitness)
    on_exit(fn -> Application.delete_env(:harness, :insights_script) end)

    Application.put_env(:harness, :insights_script, fn context, _ ->
      assert Store.get("seen/record/review-run") == nil
      assert Store.get("progress") == nil
      assert Enum.any?(context["previous_findings"], &(&1["id"] == "later-9"))

      cond do
        not Enum.any?(context["previous_findings"], &(&1["id"] == "original")) ->
          {:ok, %{"read" => %{"kind" => "findings", "offset" => context["finding_next_offset"]}}}

        is_nil(context["read_result"]) ->
          source = Enum.find(context["sources"], &(&1["field"] == "record"))
          {:ok, %{"read" => %{"kind" => "source", "source_id" => source["source_id"], "offset" => source["next_offset"]}}}

        true ->
          source = context["read_result"]
          assert source["text"] =~ "TAIL_EVIDENCE"
          {:ok, %{"findings" => [InsightsWitness.finding(source, "original")]}}
      end
    end)

    assert :ok = Insights.observe("retrieved")
    assert [%{"id" => "original"}] = Insights.history("original")["revisions"]
    assert Store.get("seen/record/review-run")
    assert Enum.count(Insights.findings()["items"]) == 22
    assert :ok = Insights.observe("unchanged-after-retrieval")
  end

  test "failed or exhausted retrieval preserves evidence for the next attempt" do
    :ok = ResultStore.record_run(record([]))
    Application.put_env(:harness, :insights_witness, InsightsScriptedWitness)
    on_exit(fn -> Application.delete_env(:harness, :insights_script) end)

    Application.put_env(:harness, :insights_script, fn _, _ ->
      {:ok, %{"read" => %{"kind" => "findings", "offset" => 0}}}
    end)

    assert {:error, :retrieval_limit_reached} = Insights.observe("exhausted")
    assert Store.get("progress") == nil
    assert Store.get("seen/record/review-run") == nil
    assert Store.get("pass/exhausted")["state"] == "failed"
    Application.put_env(:harness, :insights_script, fn _, _ -> {:ok, %{"read" => %{"kind" => "write"}}} end)
    assert {:error, :invalid_read_request} = Insights.observe("invalid-read")
    assert Store.get("seen/record/review-run") == nil
  end

  test "invalid publication gets one correction with exact diagnostics before checkpointing" do
    :ok = ResultStore.record_run(record([]))
    Application.put_env(:harness, :insights_witness, InsightsScriptedWitness)
    on_exit(fn -> Application.delete_env(:harness, :insights_script) end)

    Application.put_env(:harness, :insights_script, fn context, _ ->
      source = Enum.find(context["sources"], &(&1["text"] != ""))
      finding = InsightsWitness.finding(source)
      assert Store.get("progress") == nil

      case context["publication_repair"] do
        nil ->
          {:ok, %{"findings" => [put_in(finding, ["citations", Access.at(0), "excerpt"], "invented quote")]}}

        repair ->
          assert repair["error"] == "{:invalid_finding, 0, {:invalid_citation, 0, :excerpt_not_in_source}}"

          assert get_in(repair, ["response", "findings", Access.at(0), "citations", Access.at(0), "excerpt"]) ==
                   "invented quote"

          {:ok, %{"findings" => [finding]}}
      end
    end)

    assert :ok = Insights.observe("repaired-publication")
    assert Store.get("progress")
    assert [_] = Insights.findings()["items"]
  end

  test "repeated invalid publications stop after one repair and preserve the checkpoint" do
    :ok = ResultStore.record_run(record([]))
    Application.put_env(:harness, :insights_witness, InsightsScriptedWitness)
    on_exit(fn -> Application.delete_env(:harness, :insights_script) end)
    owner = self()

    Application.put_env(:harness, :insights_script, fn context, _ ->
      send(owner, {:publication_attempt, context["publication_repair"]})
      {:ok, %{"findings" => [nil]}}
    end)

    assert {:error, {:invalid_finding, 0, :expected_finding_object}} = Insights.observe("invalid-publication")
    assert_received {:publication_attempt, nil}
    assert_received {:publication_attempt, %{"error" => _}}
    refute_received {:publication_attempt, _}
    assert Store.get("progress") == nil
    assert Store.get("seen/record/review-run") == nil
    assert Store.get("pass/invalid-publication")["error"] =~ "expected_finding_object"
    assert Insights.findings()["items"] == []
  end

  defp evidence_record(opts), do: record(opts)
end
