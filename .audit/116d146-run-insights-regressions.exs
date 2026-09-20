defmodule InsightsArchitectReviewTest do
  use ExUnit.Case, async: false
  alias Harness.Insights
  alias Harness.Insights.{Store, Evidence}
  alias Harness.ResultStore
  alias Harness.ResultStore.Memory

  setup do
    Application.put_env(:harness, :result_store, {Memory, scope: __MODULE__})
    Memory.reset(scope: __MODULE__)
    Store.get("settings")
    :ets.delete_all_objects(Store)
    Harness.ProjectRegistry.reset()
    :ok = Harness.ProjectRegistry.register(Harness.ProjectFixture.from_repo("/tmp/insights-review", name: "review"))
    Application.put_env(:harness, :insights_witness, Harness.Test.InsightsWitness)
    Application.put_env(:harness, :insights_test_owner, self())
    Application.put_env(:harness, :insights_test_response, {:ok, %{"findings" => []}})
    :ok = Insights.configure(Map.put(Insights.settings(), "enabled", true))
    :ok
  end

  defp record(opts), do: Harness.ResultStoreContract.log_record(Keyword.merge([project_name: "review", run_id: "review-run", agent_output: "done", reviewer_output: "approved", started_at: DateTime.utc_now()], opts))

  test "structured reviewer concerns are available and concern-only updates reach the witness" do
    first = record(review_concerns: ["REVIEW_CONCERN_ALPHA"])
    :ok = ResultStore.record_run(first)
    :ok = Insights.observe("concern-first")
    assert_received {:observed, context, _}
    assert Jason.encode!(context["sources"]) =~ "REVIEW_CONCERN_ALPHA"
    :ok = ResultStore.record_run(%{first | review_concerns: ["REVIEW_CONCERN_BETA"]})
    :ok = Insights.observe("concern-second")
    assert_received {:observed, changed, _}
    assert Jason.encode!(changed["sources"]) =~ "REVIEW_CONCERN_BETA"
  end

  test "an old relevant finding gets the changed evidence before it is consumed" do
    :ok = Store.put_many([{"finding/old", "finding", %{"id" => "old", "title" => "Original recurring problem", "projects" => ["review"], "runs" => ["review-run"], "citations" => []}}])
    :ok = Store.put_many(for n <- 1..10, do: {"finding/new-#{n}", "finding", %{"id" => "new-#{n}", "title" => "Unrelated", "projects" => ["other"], "runs" => [], "citations" => []}})
    :ok = ResultStore.record_run(record(review_report: "The original recurring problem returned"))
    :ok = Insights.observe("memory-first")
    assert_received {:observed, context, _}
    :ok = Insights.observe("memory-next")
    refute_received {:observed, _, _}
    assert Enum.any?(context["previous_findings"], &(&1["id"] == "old"))
  end

  test "source marked available does not silently lose review report content" do
    :ok = ResultStore.record_run(record(review_report: String.duplicate("x", 5000) <> "TAIL_REVIEW_FINDING"))
    {:ok, batch} = Evidence.batch(%{})
    source = Enum.find(batch.sources, &(&1["field"] == "record"))
    assert source["availability"] == "available"
    assert source["text"] =~ "TAIL_REVIEW_FINDING"
  end
end
