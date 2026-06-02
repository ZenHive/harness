defmodule Harness.AgentRegistryTest do
  use ExUnit.Case, async: false

  alias Harness.AgentAdapter.Antigravity
  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Claude
  alias Harness.AgentAdapter.Codex
  alias Harness.AgentAdapter.Cursor
  alias Harness.AgentAdapter.Grok
  alias Harness.AgentAdapter.Pi
  alias Harness.AgentRegistry

  defmodule NoResumeAdapter do
    @moduledoc false
    def capabilities, do: %Capabilities{session_resume: false}
  end

  defmodule ResumeAdapter do
    @moduledoc false
    def capabilities, do: %Capabilities{session_resume: true}
  end

  defmodule FreeAdapter do
    @moduledoc false
    def capabilities, do: %Capabilities{session_resume: true, cost_tier: :free}
  end

  setup do
    AgentRegistry.reset()
    :ok
  end

  test "selects the first available adapter that supports all requested capabilities" do
    assert {:ok, ResumeAdapter} =
             AgentRegistry.select([NoResumeAdapter, ResumeAdapter], required_capabilities: [:session_resume])
  end

  test "rejects a request when no available adapter supports a required capability" do
    assert {:error, {:unsupported_capability, :session_resume, [NoResumeAdapter]}} =
             AgentRegistry.select([NoResumeAdapter], required_capabilities: [:session_resume])
  end

  describe "filter_by_cost_tier/2" do
    test "returns adapters declaring :free" do
      adapters = [NoResumeAdapter, ResumeAdapter, FreeAdapter]

      assert [FreeAdapter] = AgentRegistry.filter_by_cost_tier(adapters, :free)
    end

    test "returns adapters declaring :metered (the default tier)" do
      adapters = [NoResumeAdapter, ResumeAdapter, FreeAdapter]

      assert [NoResumeAdapter, ResumeAdapter] =
               AgentRegistry.filter_by_cost_tier(adapters, :metered)
    end

    test "returns [] when no adapter matches the tier" do
      assert [] = AgentRegistry.filter_by_cost_tier([NoResumeAdapter, ResumeAdapter], :free)
    end

    test "raises on an unknown cost tier (guards typos at call sites)" do
      assert_raise FunctionClauseError, fn ->
        AgentRegistry.filter_by_cost_tier([FreeAdapter], :bogus)
      end
    end
  end

  test "mark_unavailable/2 records a reviewer-stuck reason readable from list_unavailable/0" do
    report = "implementer hit a usage limit; nothing in the worktree to fix"

    assert :ok = AgentRegistry.mark_unavailable(ResumeAdapter, {:review_stuck, "task-7", report})
    refute AgentRegistry.available?(ResumeAdapter)
    assert [{ResumeAdapter, {:review_stuck, "task-7", ^report}}] = AgentRegistry.list_unavailable()
  end

  test "mark_available/1 lifts a previously marked adapter back into availability" do
    assert :ok = AgentRegistry.mark_unavailable(ResumeAdapter, :manual)
    refute AgentRegistry.available?(ResumeAdapter)
    assert :ok = AgentRegistry.mark_available(ResumeAdapter)
    assert AgentRegistry.available?(ResumeAdapter)
    assert [] = AgentRegistry.list_unavailable()
  end

  test "select/2 surfaces :no_available_agent when every capable adapter is unavailable" do
    :ok = AgentRegistry.mark_unavailable(ResumeAdapter, :test_only)

    assert {:error, {:no_available_agent, [ResumeAdapter]}} =
             AgentRegistry.select([ResumeAdapter], required_capabilities: [:session_resume])
  end

  describe "operator enable/disable gate (Harness.Agent.Settings)" do
    setup do
      prior = Application.get_env(:harness, :agent_disabled)
      on_exit(fn -> restore_env(:agent_disabled, prior) end)
      :ok
    end

    test "select/2 skips an operator-disabled agent and falls over to an enabled sibling" do
      Application.put_env(:harness, :agent_disabled, [:claude])

      assert {:ok, Codex} = AgentRegistry.select([Claude, Codex])
    end

    test "select/2 surfaces :no_available_agent when the only capable agent is disabled" do
      Application.put_env(:harness, :agent_disabled, [:claude])

      assert {:error, {:no_available_agent, [Claude]}} = AgentRegistry.select([Claude])
    end

    test "an enabled agent is selected normally" do
      Application.put_env(:harness, :agent_disabled, [])

      assert {:ok, Claude} = AgentRegistry.select([Claude])
    end

    defp restore_env(key, nil), do: Application.delete_env(:harness, key)
    defp restore_env(key, value), do: Application.put_env(:harness, key, value)
  end

  describe "agents/0 + all/0 + delegatable_agents/0" do
    test "agents/0 returns all six adapters" do
      agents = AgentRegistry.agents()

      assert agents.claude == Claude
      assert agents.codex == Codex
      assert agents.cursor == Cursor
      assert agents.grok == Grok
      assert agents.antigravity == Antigravity
      assert agents.pi == Pi
    end

    test "all/0 returns the six adapter modules" do
      adapters = AgentRegistry.all()

      assert length(adapters) == 6
      assert Claude in adapters
      assert Pi in adapters
    end

    test "delegatable_agents/0 returns every harness adapter (rmap renders each natively)" do
      delegatable = AgentRegistry.delegatable_agents()

      assert delegatable |> Map.keys() |> Enum.sort() ==
               [:antigravity, :claude, :codex, :cursor, :grok, :pi]
    end
  end

  describe "module_for_agent/1" do
    test "resolves each known agent atom" do
      assert {:ok, Claude} = AgentRegistry.module_for_agent(:claude)
      assert {:ok, Codex} = AgentRegistry.module_for_agent(:codex)
      assert {:ok, Cursor} = AgentRegistry.module_for_agent(:cursor)
      assert {:ok, Grok} = AgentRegistry.module_for_agent(:grok)
      assert {:ok, Antigravity} = AgentRegistry.module_for_agent(:antigravity)
      assert {:ok, Pi} = AgentRegistry.module_for_agent(:pi)
    end

    test "rejects an unknown agent atom" do
      assert {:error, {:unsupported_agent, :unknown}} = AgentRegistry.module_for_agent(:unknown)
    end
  end

  describe "delegatable_module_for_agent/1" do
    test "resolves every harness adapter — all six render natively and are delegatable" do
      assert {:ok, Claude} = AgentRegistry.delegatable_module_for_agent(:claude)
      assert {:ok, Codex} = AgentRegistry.delegatable_module_for_agent(:codex)
      assert {:ok, Cursor} = AgentRegistry.delegatable_module_for_agent(:cursor)
      assert {:ok, Grok} = AgentRegistry.delegatable_module_for_agent(:grok)
      assert {:ok, Antigravity} = AgentRegistry.delegatable_module_for_agent(:antigravity)
      assert {:ok, Pi} = AgentRegistry.delegatable_module_for_agent(:pi)
    end

    test "rejects unknown atoms with :unsupported_agent" do
      assert {:error, {:unsupported_agent, :nope}} = AgentRegistry.delegatable_module_for_agent(:nope)
    end
  end

  describe "agent_for_module/1" do
    test "round-trips every known adapter module" do
      for {agent, module} <- AgentRegistry.agents() do
        assert {:ok, ^agent} = AgentRegistry.agent_for_module(module)
      end
    end

    test "rejects an unknown adapter module" do
      assert {:error, {:unsupported_adapter, NoResumeAdapter}} =
               AgentRegistry.agent_for_module(NoResumeAdapter)
    end
  end

  describe "installed?/1 + refresh_installed/0" do
    test "returns false for an unknown adapter module" do
      refute AgentRegistry.installed?(NoResumeAdapter)
    end

    test "caches the probe — second call hits the cache" do
      first = AgentRegistry.installed?(Claude)
      second = AgentRegistry.installed?(Claude)
      assert first == second

      %{installed: installed} = :sys.get_state(AgentRegistry)
      assert Map.has_key?(installed, Claude)
    end

    test "refresh_installed/0 clears the cache" do
      _ = AgentRegistry.installed?(Claude)
      assert :ok = AgentRegistry.refresh_installed()

      %{installed: installed} = :sys.get_state(AgentRegistry)
      assert installed == %{}
    end
  end
end
