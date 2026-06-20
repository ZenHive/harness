defmodule Harness.RoutingTest do
  # async: false because tests mutate AgentRegistry and global store application env.
  use ExUnit.Case, async: false

  alias Harness.Agent.Settings, as: AgentSettings
  alias Harness.AgentAdapter.Antigravity
  alias Harness.AgentAdapter.Claude
  alias Harness.AgentAdapter.Codex
  alias Harness.AgentAdapter.Cursor
  alias Harness.AgentAdapter.Grok
  alias Harness.AgentAdapter.Pi
  alias Harness.AgentRegistry
  alias Harness.Chat.Tools
  alias Harness.Config
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
    previous_agent_model = Application.get_env(:harness, :agent_model)

    Application.put_env(:harness, :result_store, store)
    Application.put_env(:harness, :settings_store, settings_store)
    Application.put_env(:harness, :agent_model, [])
    MemoryStore.reset(scope: scope)
    SettingsStoreMemory.reset(scope: scope)
    AgentRegistry.reset()
    put_installed(%{Claude => true, Codex => true, Cursor => true})
    enable_agents([:claude, :codex, :cursor])
    put_catalogs()
    put_agent_models(claude: "claude-opus-4-8", codex: "gpt-5.5", cursor: "composer-2.5")

    on_exit(fn ->
      AgentRegistry.reset()
      MemoryStore.reset(scope: scope)
      SettingsStoreMemory.reset(scope: scope)
      restore(:result_store, previous_result_store)
      restore(:settings_store, previous_settings_store)
      restore(:agent_model, previous_agent_model)
    end)

    {:ok, store: store}
  end

  test "brief joins roster, availability, and KPI facts per agent-model pair", %{store: store} do
    assert :ok = ResultStore.record_run(ResultStoreContract.log_record(run_id: "r1", agent: :codex), store)
    assert :ok = ResultStore.record_run(ResultStoreContract.log_record(run_id: "r2", agent: :codex), store)

    assert {:ok, %{pairs: pairs}} = Routing.brief(include_all: true, domains: ["otp"])
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

  test "brief surfaces reviewer false-approval facts without scoring or routing on them", %{store: store} do
    assert :ok =
             ResultStore.record_run(
               ResultStoreContract.log_record(
                 run_id: "reviewer-false-approval",
                 agent: :cursor,
                 reviewer_adapter: Codex,
                 reviewer_model: "gpt-5.5",
                 verdict: :approve,
                 approved_then_found_red: %{
                   "reviewer_agent" => "codex",
                   "reviewer_model" => "gpt-5.5",
                   "cold_check" => %{"passed" => false}
                 }
               ),
               store
             )

    assert {:ok, %{pairs: pairs} = brief} = Routing.brief(include_all: true)
    codex = pair!(pairs, "codex", "gpt-5.5")

    assert codex.kpi.reviewer_false_approval == %{value: 1.0, n: 1, count: 1}
    assert codex.kpi.reviewer_rejection == %{value: 0.0, n: 1, count: 0}
    assert codex.kpi.reviewer_no_verdict == %{value: 0.0, n: 1, count: 0}
    refute Map.has_key?(codex.kpi, :reviewer_score)
    refute Map.has_key?(codex.kpi, :reviewer_weight)
    refute Map.has_key?(codex.kpi, :reviewer_penalty)
    refute Map.has_key?(codex.kpi, :reviewer_excluded)
    refute_fused_keys(brief)
  end

  test "blocked model pairs are annotated instead of silently dropped" do
    assert :ok = ModelAvailability.block_model("cursor", "composer-2.5", reason: "operator quota")

    assert {:ok, %{pairs: pairs}} = Routing.brief(include_all: true, domains: ["otp"])
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

  test "default brief returns one configured-model row per installed enabled available agent" do
    assert {:ok, %{pairs: pairs}} = Routing.brief(domains: ["otp"])

    assert Enum.map(pairs, &{&1.agent, &1.model, &1.model_required}) == [
             {"claude", "claude-opus-4-8", false},
             {"codex", "gpt-5.5", false},
             {"cursor", "composer-2.5", false}
           ]
  end

  test "default brief uses the configured model when it is not the first catalog model" do
    put_catalogs(%{
      cursor: [
        %{id: "composer-2.5", label: "Composer 2.5", annotations: []},
        %{id: "claude-opus-4-8-thinking-high", label: "Opus 4.8 high", annotations: []}
      ]
    })

    assert :ok = Config.put({:agent_model, :cursor}, "claude-opus-4-8-thinking-high", "test")

    assert {:ok, %{pairs: pairs}} = Routing.brief(agents: nil)

    assert pair!(pairs, "cursor", "claude-opus-4-8-thinking-high").model_required == false
    refute Enum.any?(pairs, &(&1.agent == "cursor" and &1.model == "composer-2.5"))
  end

  test "default brief surfaces a model-required row for model-capable agents without a configured model" do
    put_installed(%{Grok => true})
    enable_agents([:grok])
    put_catalogs(%{grok: [%{id: "grok-4.3", label: "Grok 4.3", annotations: []}]})

    assert {:ok, %{pairs: pairs}} = Routing.brief()
    grok = pair!(pairs, "grok", nil)

    assert grok.model_required == true
    assert grok.availability.available == false
    refute Enum.any?(pairs, &(&1.agent == "grok" and &1.model == "grok-4.3"))
  end

  test "default brief keeps antigravity as a single model-less available row" do
    put_installed(%{Antigravity => true})
    enable_agents([:antigravity])

    assert {:ok, %{pairs: pairs}} = Routing.brief()
    antigravity = pair!(pairs, "antigravity", nil)

    assert antigravity.model_required == false
    assert antigravity.availability.available == true
  end

  test "default brief returns only installed enabled available configured-model pairs" do
    assert :ok = AgentSettings.set_enabled(:claude, false, "test")
    assert :ok = ModelAvailability.block_model("cursor", "composer-2.5", reason: "operator quota")

    assert {:ok, %{pairs: pairs}} = Routing.brief(domains: ["otp"])

    assert Enum.map(pairs, &{&1.agent, &1.model}) == [{"codex", "gpt-5.5"}]
  end

  test "include_all restores blocked and disabled catalog pairs" do
    assert :ok = AgentSettings.set_enabled(:claude, false, "test")
    assert :ok = ModelAvailability.block_model("cursor", "composer-2.5", reason: "operator quota")

    assert {:ok, %{pairs: pairs}} = Routing.brief(include_all: true, domains: ["otp"])

    assert pair!(pairs, "claude", "claude-opus-4-8").roster.enabled == false
    assert pair!(pairs, "cursor", "composer-2.5").availability.blocked == true
    assert pair!(pairs, "codex", "gpt-5.5").availability.available == true
  end

  test "agents filter narrows the returned pairs and ignores unknown agents" do
    assert {:ok, %{pairs: pairs}} = Routing.brief(agents: ["codex", "missing"])

    assert Enum.map(pairs, & &1.agent) == ["codex"]
    assert pair!(pairs, "codex", "gpt-5.5")
  end

  test "agents filter expands the selected agent to its full available catalog" do
    put_catalogs(%{
      cursor: [
        %{id: "composer-2.5", label: "Composer 2.5", annotations: []},
        %{id: "claude-opus-4-8-thinking-high", label: "Opus 4.8 high", annotations: []}
      ]
    })

    assert :ok = Config.put({:agent_model, :cursor}, "composer-2.5", "test")

    assert {:ok, %{pairs: pairs}} = Routing.brief(agents: ["cursor"])

    assert Enum.map(pairs, &{&1.agent, &1.model}) == [
             {"cursor", "claude-opus-4-8-thinking-high"},
             {"cursor", "composer-2.5"}
           ]
  end

  test "fields projection returns exactly known requested pair keys and ignores unknown fields" do
    assert {:ok, %{pairs: pairs}} = Routing.brief(agents: ["codex"], fields: ["agent", "availability", "unknown"])

    [pair] = pairs
    assert pair |> Map.keys() |> Enum.sort() == [:agent, :availability]
    assert pair.agent == "codex"
    assert pair.availability.available == true
  end

  test "JSON map options use string keys from MCP callers" do
    assert {:ok, %{domains: ["otp"], pairs: pairs}} =
             Routing.brief(%{
               "agents" => ["codex"],
               "domains" => ["otp"],
               "fields" => ["agent"],
               "include_all" => false,
               "unknown" => true
             })

    assert pairs == [%{agent: "codex"}]
  end

  test "top-level arguments support the direct MCP parameter order" do
    assert {:ok, %{domains: ["otp"], pairs: pairs}} = Routing.brief(["otp"], ["codex"], ["agent", "kpi"], false)

    [pair] = pairs
    assert pair |> Map.keys() |> Enum.sort() == [:agent, :kpi]
    assert pair.agent == "codex"
    assert pair.kpi.domains == ["otp"]
  end

  test "domains option still scopes KPI cells" do
    assert {:ok, %{domains: ["otp"], pairs: pairs}} = Routing.brief(domains: ["otp"], agents: ["codex"])

    assert pair!(pairs, "codex", "gpt-5.5").kpi.domains == ["otp"]
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
    assert Map.has_key?(tool.inputSchema.properties, :agents)
    assert Map.has_key?(tool.inputSchema.properties, :fields)
    assert Map.has_key?(tool.inputSchema.properties, :include_all)
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

  @spec pair!([map()], String.t(), String.t() | nil) :: map()
  defp pair!(pairs, agent, model) do
    Enum.find(pairs, &(&1.agent == agent and &1.model == model)) ||
      flunk("missing routing pair #{agent}/#{model}; got #{inspect(Enum.map(pairs, &{&1.agent, &1.model}))}")
  end

  @spec put_catalogs() :: :ok
  defp put_catalogs(extra_catalogs \\ %{}) do
    catalogs =
      Map.merge(
        %{
          codex: [%{id: "gpt-5.5", label: "GPT-5.5", annotations: []}],
          claude: [%{id: "claude-opus-4-8", label: "Opus 4.8", annotations: []}],
          cursor: [%{id: "composer-2.5", label: "Composer 2.5", annotations: []}]
        },
        extra_catalogs
      )

    SettingsStore.put(ModelAvailability.static_catalogs_key(), catalogs)
  end

  @spec put_installed(%{module() => boolean()}) :: :ok
  defp put_installed(installed) do
    installed =
      Map.merge(
        %{Claude => false, Codex => false, Cursor => false, Grok => false, Antigravity => false, Pi => false},
        installed
      )

    :sys.replace_state(AgentRegistry, fn state -> %{state | installed: installed} end)
    :ok
  end

  @spec enable_agents([atom()]) :: :ok
  defp enable_agents(agents) do
    Enum.each(agents, &AgentSettings.set_enabled(&1, true, "test"))
  end

  @spec put_agent_models(keyword(String.t())) :: :ok
  defp put_agent_models(models) do
    Enum.each(models, fn {agent, model} -> Config.put({:agent_model, agent}, model, "test") end)
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
