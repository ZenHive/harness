defmodule Harness.MapContractsTest do
  @moduledoc """
  Triage note for the `mix reach.check --arch --smells` repeated-map-shape
  (`fixed_shape_map`) findings reported on 2026-06-30 (Task 338).

  Each finding was classified as a shared contract, a local UI literal, an
  external/JSON-native payload, or transient construction data, then given the
  disposition below. This module tests the structs introduced for the shared
  contracts so future Reach runs can distinguish intentional maps from untriaged
  debt.

  Shared contracts → named struct (drift-prone, crosses module boundaries):

    * code-search rows (`Harness.CodeSearch` definition/call-edge/duplicate facts)
      → `Harness.CodeSearch.Fact`
    * KPI recovery token totals (`Harness.AgentKPI`)
      → `Harness.AgentKPI.TokenTotals`
    * dispatch summaries (`Harness.Dispatch` run + await-runs rows)
      → `Harness.Dispatch.RunSummary` and `Harness.Dispatch.AwaitRunsSummary`
    * routing-brief availability cells (`Harness.Routing`)
      → `Harness.Routing.Availability`
    * model-availability catalog rows (`Harness.ModelAvailability`)
      → `Harness.ModelAvailability.CatalogEntry` (with `coerce/1` for persisted rows)
    * dispatch-recommend payload (`Harness.CapabilityScore`)
      → `Harness.CapabilityScore.Recommendation`
    * parsed transcript snapshot (`Harness.Dashboard.Transcript.Parser`)
      → `Harness.Run.TranscriptSnapshot`

  Kept as maps (disposition made explicit at the site):

    * transcript assistant tool-use blocks → JSON-native payload, centralized in
      `Harness.Dashboard.Transcript.Parser.assistant_tool_use_payload/3` (one
      constructor, one shape) rather than restructured away from the wire form.
    * dashboard UI literals — LiveView stream items and tool-call cards
      (`Harness.Dashboard.ChatLive`, `Harness.Dashboard.Components`), verdict
      badges (`Harness.Dashboard.CompareLive`), and config-inspector rows
      (`Harness.Dashboard.ConfigInspector`) — de-duplicated behind single private
      constructors (`stream_message/1`, `ui_tool_call/3`, `verdict_badge/3`,
      `inspector_row/4`) with explanatory comments; view-local, not shared domain.
    * `Supervisor` / `DynamicSupervisor` child-spec literals (config, run, oban,
      chat supervisor, worktree sweeper, dashboard MCP server, migration guard) →
      transient framework construction data, suppressed with
      `# reach:disable-next-line fixed_shape_map` and a one-line rationale.
  """

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
