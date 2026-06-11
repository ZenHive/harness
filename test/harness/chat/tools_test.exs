defmodule Harness.Chat.ToolsTest do
  use ExUnit.Case, async: false

  alias Harness.AgentAdapter.Claude
  alias Harness.Batch.Result, as: BatchResult
  alias Harness.CapabilityScore.Legacy, as: CapabilityScore
  alias Harness.Chat.Tools
  alias Harness.ResultStore
  alias Harness.ResultStore.Memory, as: MemoryStore
  alias Harness.ResultStoreContract

  test "build/0 resolves MCP tool names to MFAs" do
    registry = Tools.build()

    assert map_size(registry) > 0
    assert %{module: Harness.ProjectRegistry, function: :list} = registry["project_registry-list"]
  end

  test "schemas/1 returns backend-ready tool maps" do
    registry = Tools.build()

    tool =
      registry
      |> Tools.schemas()
      |> Enum.find(&(&1.name == "project_registry-list"))

    assert %{description: desc, input_schema: schema} = tool
    assert is_binary(desc)
    assert Map.get(schema, "type") || Map.get(schema, :type) == "object"
  end

  test "dispatch/3 decodes atom params from colon-prefixed strings" do
    registry = Tools.build()

    assert {:ok, {:ok, Harness.AgentAdapter.Codex}} =
             Tools.dispatch(registry, "audit_review-default_grader", %{"implementer" => ":claude"})
  end

  test "dispatch/3 returns unknown_tool for missing names" do
    registry = Tools.build()
    assert {:error, {:unknown_tool, "missing-tool"}} = Tools.dispatch(registry, "missing-tool", %{})
  end

  # Review fix #9: an explicitly-passed `null` for an optional param with a
  # default coalesces to that default (LLM callers routinely emit null for
  # unset params) rather than being decoded as a literal nil value. Guards
  # against a regression that would forward nil and break the function guard.
  test "dispatch/3 coalesces an explicit null for a defaulted param to its default" do
    registry = Tools.build()

    # `filters` defaults to []; a nil forwarded instead would fail the
    # `when is_list(filters)` guard. The outer {:ok, _} is dispatch's success
    # wrapper, the inner is list_run_records's own {:ok, list} return.
    assert {:ok, {:ok, with_null}} =
             Tools.dispatch(registry, "result_store-list_run_records", %{"filters" => nil})

    assert is_list(with_null)

    # Absent key resolves to the same default — the present-vs-absent branch
    # must not diverge for a defaulted param.
    assert {:ok, {:ok, absent}} =
             Tools.dispatch(registry, "result_store-list_run_records", %{})

    assert is_list(absent)
  end

  test "tool names use the single Manifest delimiter (not '__') so client namespacing produces only one '__'" do
    delim = Harness.Manifest.tool_name_delimiter()
    assert delim == "-"

    registry = Tools.build()
    names = Map.keys(registry)

    assert "dispatch-task" in names
    assert "roadmap-list" in names
    assert "result_store-list_run_records" in names

    # Core fix: no tool name contains the old group__action joiner.
    # After a client namespaces as <server>__<tool>, qualified has "__" exactly once.
    for name <- names do
      refute name =~ "__",
             "tool name #{inspect(name)} must not contain '__' (would become double after client ns)"
    end

    # Simulate client namespacing (as grok and strict MCP clients do); only one "__".
    sample = "dispatch-task"
    qualified = "harness__" <> sample
    assert qualified == "harness__dispatch-task"
    assert length(Regex.scan(~r/__/, qualified)) == 1
  end

  test "dispatch/3 translates JSON-shaped (string-keyed map) filters for result_store-list_run_records, atomizing known keys and ignoring unknowns" do
    registry = Tools.build()

    # Documented keys only (run_id, batch_id, agent, adapter, verdict, project_name) — must succeed and yield a list.
    assert {:ok, {:ok, list1}} =
             Tools.dispatch(registry, "result_store-list_run_records", %{"filters" => %{"run_id" => "r-123"}})

    assert is_list(list1)

    # Mix of documented + unknown keys: unknowns ignored (no crash, no poisoning of good keys).
    assert {:ok, {:ok, list2}} =
             Tools.dispatch(
               registry,
               "result_store-list_run_records",
               %{"filters" => %{"run_id" => "r-123", "project_name" => "harness", "bogus" => true, "extra" => 1}}
             )

    assert is_list(list2)

    # Empty map (no filters) also accepted.
    assert {:ok, {:ok, list3}} =
             Tools.dispatch(registry, "result_store-list_run_records", %{"filters" => %{}})

    assert is_list(list3)
  end

  # An object/keyword param can reach dispatch as a JSON-encoded *string* (not a
  # JSON object): descripex emits a typeless schema for `kind: :value`, so an MCP
  # client with no type hint serializes the value as JSON text. Reproduced over
  # the wire — anubis delivered `%{"filters" => "{\"agent\": \"cursor\"}"}` and the
  # binary fell through undecoded, crashing list_run_records/1's `is_list` guard.
  test "dispatch/3 decodes a JSON-string-encoded keyword param (MCP clients stringify typeless object args)" do
    registry = Tools.build()

    # A stringified JSON object decodes to a keyword list, atomizing known keys.
    assert {:ok, {:ok, list1}} =
             Tools.dispatch(
               registry,
               "result_store-list_run_records",
               %{"filters" => ~s({"run_id": "r-123", "bogus": true})}
             )

    assert is_list(list1)

    # A stringified empty object is also accepted (no filters).
    assert {:ok, {:ok, list2}} =
             Tools.dispatch(registry, "result_store-list_run_records", %{"filters" => "{}"})

    assert is_list(list2)

    # A non-JSON string for a keyword param passes through unchanged; the target
    # function's guard then rejects it as a dispatch failure rather than crashing
    # the dispatcher — we don't silently coerce garbage into an empty filter set.
    assert {:error, {:dispatch_failed, _msg}} =
             Tools.dispatch(registry, "result_store-list_run_records", %{"filters" => "not json"})
  end

  describe "result store read tool store defaults" do
    setup do
      root =
        Path.join(
          System.tmp_dir!(),
          "harness_chat_tools_result_store_#{System.unique_integer([:positive])}"
        )

      previous = Application.get_env(:harness, :result_store)
      store = {MemoryStore, root: root}
      Application.put_env(:harness, :result_store, store)
      MemoryStore.reset(root: root)

      on_exit(fn ->
        restore_result_store(previous)
        MemoryStore.reset(root: root)
      end)

      {:ok, store: store}
    end

    test "aggregate_by_agent dispatch without store reads the configured store", %{store: store} do
      registry = Tools.build()
      record = ResultStoreContract.log_record(run_id: "mcp-kpi-default", agent: :codex)

      assert :ok = ResultStore.record_run(record, store)

      assert {:ok, {:ok, ledger}} = Tools.dispatch(registry, "result_store-aggregate_by_agent", %{})
      assert Map.has_key?(ledger, :codex)

      assert {:ok, {:ok, %{}}} =
               Tools.dispatch(registry, "result_store-aggregate_by_agent", %{"store" => false})
    end

    test "load_batch dispatch without store reads the configured store", %{store: store} do
      registry = Tools.build()
      batch = %BatchResult{batch_id: "mcp-batch-default", total: 0, max_concurrency: 1, results: []}

      assert :ok = ResultStore.save_batch(batch, store)

      assert {:ok, {:ok, loaded}} =
               Tools.dispatch(registry, "result_store-load_batch", %{"batch_id" => "mcp-batch-default"})

      assert loaded.batch_id == "mcp-batch-default"

      assert {:ok, {:error, :disabled}} =
               Tools.dispatch(
                 registry,
                 "result_store-load_batch",
                 %{"batch_id" => "mcp-batch-default", "store" => false}
               )
    end

    test "aggregate_reviewer_reliability dispatch without store reads the configured store", %{store: store} do
      registry = Tools.build()

      record =
        ResultStoreContract.log_record(
          run_id: "mcp-reviewer-default",
          verdict: :reject,
          reviewer_adapter: Claude
        )

      assert :ok = ResultStore.record_run(record, store)

      assert {:ok, {:ok, ledger}} =
               Tools.dispatch(registry, "result_store-aggregate_reviewer_reliability", %{})

      assert %{reviewed_count: 1, rejection_count: 1} = ledger[Claude]

      assert {:ok, {:ok, %{}}} =
               Tools.dispatch(registry, "result_store-aggregate_reviewer_reliability", %{"store" => false})
    end

    test "aggregate_ceremony_cost dispatch without store reads the configured store", %{store: store} do
      registry = Tools.build()
      record = ResultStoreContract.log_record(run_id: "mcp-ceremony-default", verdict: :approve)

      assert :ok = ResultStore.record_run(record, store)

      assert {:ok, {:ok, ceremony_cost}} =
               Tools.dispatch(registry, "result_store-aggregate_ceremony_cost", %{})

      assert ceremony_cost.run_count == 1

      assert {:ok, {:ok, disabled_cost}} =
               Tools.dispatch(registry, "result_store-aggregate_ceremony_cost", %{"store" => false})

      assert disabled_cost.run_count == 0
    end

    test "get_capability_score dispatch without store reads the configured store", %{store: store} do
      registry = Tools.build()
      score = capability_score()

      assert :ok = ResultStore.save_capability_score(score, store)

      args = %{"agent" => ":codex", "domain" => ":otp", "corpus_version" => "mcp-default"}

      assert {:ok, {:ok, loaded}} =
               Tools.dispatch(registry, "result_store-get_capability_score", args)

      assert loaded.agent == :codex
      assert loaded.domain == :otp
      assert loaded.corpus_version == "mcp-default"

      assert {:ok, :no_data} =
               Tools.dispatch(registry, "result_store-get_capability_score", Map.put(args, "store", false))
    end

    test "list_capability_scores dispatch without store reads the configured store", %{store: store} do
      registry = Tools.build()
      score = capability_score()

      assert :ok = ResultStore.save_capability_score(score, store)

      assert {:ok, {:ok, [listed]}} =
               Tools.dispatch(registry, "result_store-list_capability_scores", %{})

      assert listed.agent == :codex
      assert listed.domain == :otp
      assert listed.corpus_version == "mcp-default"

      assert {:ok, {:ok, []}} =
               Tools.dispatch(registry, "result_store-list_capability_scores", %{"store" => false})
    end
  end

  defp capability_score do
    %CapabilityScore{
      agent: :codex,
      domain: :otp,
      corpus_version: "mcp-default",
      scored_at: ~U[2026-06-10 00:00:00Z],
      run_count: 1,
      success_rate: 1.0,
      cost_to_green: 42.0,
      mean_reviewer_diff_size: 0.0,
      mean_ratings: %{"otp" => 9.0},
      composite_score: 1.0,
      raw_metrics: []
    }
  end

  defp restore_result_store(nil), do: Application.delete_env(:harness, :result_store)
  defp restore_result_store(value), do: Application.put_env(:harness, :result_store, value)
end
