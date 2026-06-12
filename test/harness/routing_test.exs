defmodule Harness.RoutingTest do
  # async: false because tests mutate AgentRegistry and global store application env.
  use ExUnit.Case, async: false

  alias Harness.AgentAdapter.Claude
  alias Harness.AgentAdapter.Codex
  alias Harness.AgentAdapter.Cursor
  alias Harness.AgentRegistry
  alias Harness.Chat.Tools
  alias Harness.ModelAvailability
  alias Harness.ResultStore
  alias Harness.ResultStore.Memory, as: MemoryStore
  alias Harness.ResultStoreContract
  alias Harness.Routing
  alias Harness.SettingsStore
  alias Harness.Test.SettingsStoreMemory

  setup do
    scope = :"routing_#{System.unique_integer([:positive])}"
    store = {MemoryStore, scope: scope}
    settings_store = {SettingsStoreMemory, scope: scope}
    previous_result_store = Application.get_env(:harness, :result_store)
    previous_settings_store = Application.get_env(:harness, :settings_store)

    Application.put_env(:harness, :result_store, store)
    Application.put_env(:harness, :settings_store, settings_store)
    MemoryStore.reset(scope: scope)
    SettingsStoreMemory.reset(scope: scope)
    AgentRegistry.reset()
    put_installed(%{Claude => true, Codex => true, Cursor => true})
    put_catalogs()

    on_exit(fn ->
      AgentRegistry.reset()
      MemoryStore.reset(scope: scope)
      SettingsStoreMemory.reset(scope: scope)
      restore(:result_store, previous_result_store)
      restore(:settings_store, previous_settings_store)
    end)

    {:ok, store: store}
  end

  test "brief joins roster, availability, and KPI facts per agent-model pair", %{store: store} do
    assert :ok = ResultStore.record_run(ResultStoreContract.log_record(run_id: "r1", agent: :codex), store)
    assert :ok = ResultStore.record_run(ResultStoreContract.log_record(run_id: "r2", agent: :codex), store)

    assert {:ok, %{pairs: pairs}} = Routing.brief(["otp"])
    codex = pair!(pairs, "codex", "gpt-5.5")

    assert %{
             roster: %{
               installed: true,
               enabled: true,
               reviewer_eligible: true,
               cost_tier: "metered",
               capabilities: %{worktree_isolation: true}
             },
             availability: %{available: true, blocked: false, reason: nil},
             kpi: %{
               n: 2,
               success_rate: %{n: 2, value: 1.0},
               first_attempt_pass: %{n: 2, value: 1.0},
               duration_p90: %{n: 2, value: 1234},
               cost_to_approved: %{n: 2, value: cost_to_approved}
             }
           } = codex

    assert cost_to_approved == 0.0
    refute Map.has_key?(codex, :capability)
  end

  test "blocked model pairs are annotated instead of silently dropped" do
    assert :ok = ModelAvailability.block_model("cursor", "composer-2.5", reason: "operator quota")

    assert {:ok, %{pairs: pairs}} = Routing.brief(["otp"])
    cursor = pair!(pairs, "cursor", "composer-2.5")

    assert %{
             availability: %{
               available: false,
               blocked: true,
               reason: "operator quota",
               source: "operator"
             }
           } = cursor
  end

  test "domain cold-start surfaces n zero and explore candidate through KPI" do
    assert {:ok, %{pairs: pairs}} = Routing.brief(["otp"])
    codex = pair!(pairs, "codex", "gpt-5.5")

    assert %{kpi: %{n: 0, explore_candidate: true}} = codex
    refute Map.has_key?(codex, :capability)
  end

  test "omitted domains argument reads the configured result store" do
    assert :ok =
             ResultStore.record_run(ResultStoreContract.log_record(run_id: "configured-store", agent: :codex))

    assert {:ok, %{pairs: pairs}} = Routing.brief()
    codex = pair!(pairs, "codex", "gpt-5.5")

    assert codex.kpi.n == 1
  end

  test "MCP and chat surfaces expose routing-brief without struct filtering" do
    assert Routing in Harness.Manifest.modules()

    tool = Enum.find(Harness.Manifest.mcp_tools(), &(&1.name == "routing-brief"))
    assert tool
    assert Map.has_key?(tool.inputSchema.properties, :domains)
    assert tool.inputSchema.required == []

    assert %{module: Routing, function: :brief} = Tools.build()["routing-brief"]
  end

  test "MCP and chat surfaces do not expose legacy capability cell tools" do
    mcp_tool_names = Enum.map(Harness.Manifest.mcp_tools(), & &1.name)
    chat_tools = Tools.build()

    for removed <- ~w(
           result_store-save_capability_score
           result_store-get_capability_score
           result_store-list_capability_scores
         ) do
      refute removed in mcp_tool_names
      refute Map.has_key?(chat_tools, removed)
    end
  end

  test "brief contains no fused routing verdict or ranking keys" do
    assert {:ok, brief} = Routing.brief(["otp"])

    refute_fused_keys(brief)
  end

  @spec pair!([map()], String.t(), String.t()) :: map()
  defp pair!(pairs, agent, model) do
    Enum.find(pairs, &(&1.agent == agent and &1.model == model)) ||
      flunk("missing routing pair #{agent}/#{model}; got #{inspect(Enum.map(pairs, &{&1.agent, &1.model}))}")
  end

  @spec put_catalogs() :: :ok
  defp put_catalogs do
    SettingsStore.put(ModelAvailability.static_catalogs_key(), %{
      codex: [%{id: "gpt-5.5", label: "GPT-5.5", annotations: []}],
      cursor: [%{id: "composer-2.5", label: "Composer 2.5", annotations: []}]
    })
  end

  @spec put_installed(%{module() => boolean()}) :: :ok
  defp put_installed(installed) do
    :sys.replace_state(AgentRegistry, fn state -> %{state | installed: installed} end)
    :ok
  end

  @spec refute_fused_keys(term()) :: :ok
  defp refute_fused_keys(term) when is_map(term) do
    forbidden = ~w(best winner rank ranking route recommended composite_score)a

    for key <- Map.keys(term) do
      refute key in forbidden, "brief leaked fused routing key #{inspect(key)} in #{inspect(term)}"
    end

    term |> Map.values() |> Enum.each(&refute_fused_keys/1)
  end

  defp refute_fused_keys(term) when is_list(term), do: Enum.each(term, &refute_fused_keys/1)
  defp refute_fused_keys(_term), do: :ok

  @spec restore(atom(), term()) :: :ok
  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)
end
