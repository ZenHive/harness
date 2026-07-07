defmodule Harness.MapContractsTest do
  use ExUnit.Case, async: true

  alias Harness.AgentKPI.TokenTotals
  alias Harness.CapabilityScore.Recommendation
  alias Harness.CodeSearch.Fact
  alias Harness.Dashboard.Transcript.Parser
  alias Harness.Dispatch.AwaitRunsSummary
  alias Harness.Dispatch.RunSummary
  alias Harness.ModelAvailability.CatalogEntry
  alias Harness.Routing.Availability
  alias Harness.Run.TranscriptSnapshot
  alias Harness.TokenUsage

  test "CodeSearch.Fact carries definition fields" do
    fact =
      Fact.new(
        file: "lib/a.ex",
        line: 1,
        kind: :def,
        module: "A",
        name: "foo",
        arity: 2
      )

    assert fact.file == "lib/a.ex"
    assert fact.arity == 2
  end

  test "CatalogEntry coerces persisted map rows" do
    entry = CatalogEntry.coerce(%{id: "gpt-5.5", label: "GPT-5.5", annotations: ["default"]})
    assert entry.id == "gpt-5.5"
    assert entry.annotations == ["default"]
  end

  test "Routing.Availability is the routing-brief availability cell" do
    cell =
      Availability.new(
        model: "composer-2.5",
        model_required: false,
        label: "Composer",
        available: true,
        blocked: false
      )

    assert cell.model == "composer-2.5"
    assert cell.available
  end

  test "Dispatch summaries are structs with stable fields" do
    assert %AwaitRunsSummary{run_id: "r1", state: :done, reason: :approved, review_verdict: :approve} =
             AwaitRunsSummary.new("r1", :done, :approved, :approve)

    assert %RunSummary{run_id: "r1", passed: true, state: :done} =
             struct(RunSummary, run_id: "r1", state: :done, passed: true)
  end

  test "TokenTotals normalizes usage integers" do
    usage = %TokenUsage{input: 3, output: 7, total: 10}
    assert %TokenTotals{input: 3, output: 7, total: 10} = TokenTotals.from_usage(usage)
    assert %TokenTotals{input: 0, output: 0, total: 0} = TokenTotals.zero()
  end

  test "Recommendation is the dispatch-recommend payload" do
    rec =
      Recommendation.new(
        agent: :codex,
        facets: %{"surface" => "otp"},
        strategy: :explore,
        rationale: :unmeasured_facet,
        ranked: []
      )

    assert rec.agent == :codex
    assert rec.strategy == :explore
  end

  test "transcript tool-use payload is centralized" do
    payload = Parser.assistant_tool_use_payload("id-1", "read", %{path: "a.ex"})
    assert payload == %{id: "id-1", name: "read", input: %{path: "a.ex"}}
  end

  test "TranscriptSnapshot threads parsed events" do
    snapshot = %TranscriptSnapshot{events: [{:plain_text, %{text: "hi"}}], agent_kind: :codex, seq: 1}
    assert snapshot.seq == 1
    assert snapshot.agent_kind == :codex
  end
end
