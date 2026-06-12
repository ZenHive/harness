defmodule Harness.AgentsTest do
  use ExUnit.Case, async: false

  alias Harness.Agent.Settings
  alias Harness.AgentAdapter.Antigravity
  alias Harness.AgentAdapter.Claude
  alias Harness.AgentAdapter.Codex
  alias Harness.AgentAdapter.Cursor
  alias Harness.AgentAdapter.Grok
  alias Harness.AgentAdapter.Pi
  alias Harness.AgentRegistry
  alias Harness.Agents
  alias Harness.Config
  alias Harness.Test.SettingsStoreMemory

  @scope :test_default

  setup do
    AgentRegistry.reset()
    SettingsStoreMemory.reset(scope: @scope)

    prior_agent_model = Application.get_env(:harness, :agent_model)
    prior_reviewer_model = Application.get_env(:harness, :reviewer_model)

    on_exit(fn ->
      AgentRegistry.reset()
      SettingsStoreMemory.reset(scope: @scope)
      restore(:agent_model, prior_agent_model)
      restore(:reviewer_model, prior_reviewer_model)
    end)

    :ok
  end

  test "list/0 returns JSON-safe facts for every registered agent" do
    put_installed(%{Codex => true})
    assert :ok = AgentRegistry.mark_unavailable(Codex, {:quota, "later"})
    assert :ok = Settings.set_enabled(:codex, false, "test")
    assert :ok = Config.put({:agent_model, :codex}, "gpt-5.5-codex", "test")
    assert :ok = Config.put({:reviewer_model, :codex}, "gpt-5.5-high", "test")

    codex = Enum.find(Agents.list(), &(&1.agent == "codex"))

    assert %{
             agent: "codex",
             installed: true,
             available: false,
             enabled: false,
             reviewer_eligible: true,
             dispatchable_as_reviewer: true,
             cost_tier: "metered",
             capabilities: %{session_resume: true, auth_env_scrub: ["OPENAI_API_KEY"]},
             model: "gpt-5.5-codex",
             reviewer_model: "gpt-5.5-high",
             unavailable_reason: "{:quota, \"later\"}"
           } = codex

    assert Enum.map(Agents.list(), & &1.agent) == ~w(claude codex cursor grok antigravity pi)
  end

  test "reviewers/1 returns the installed reviewer slate excluding the implementer family" do
    put_installed(%{Claude => false, Codex => true, Cursor => true, Grok => true, Antigravity => false, Pi => true})

    assert :ok = Settings.set_reviewer_eligible(:pi, false, "test")
    assert :ok = AgentRegistry.mark_unavailable(Cursor, :busy)

    assert Enum.map(Agents.reviewers("codex"), & &1.agent) == ~w(grok cursor)
    assert Enum.map(Agents.reviewers(), & &1.agent) == ~w(codex grok cursor)
  end

  defp put_installed(installed) do
    :sys.replace_state(AgentRegistry, fn state -> %{state | installed: installed} end)
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)
end
