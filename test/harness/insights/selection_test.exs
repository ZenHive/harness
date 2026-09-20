defmodule Harness.Insights.SelectionTest do
  use ExUnit.Case, async: false

  alias Harness.Agent.Settings
  alias Harness.AgentAdapter.Codex
  alias Harness.AgentRegistry
  alias Harness.Insights
  alias Harness.Insights.Selection
  alias Harness.Insights.Store
  alias Harness.ModelAvailability
  alias Harness.SettingsStore

  setup do
    old = Application.get_env(:harness, :agent_model)
    keys = [:agent, :model_blocks, :model_catalogs, :model_catalog_static]
    saved = Map.new(keys, &{&1, SettingsStore.fetch_map(&1)})
    Application.put_env(:harness, :agent_model, codex: "gpt-6-astra")
    for key <- keys, do: SettingsStore.put(key, %{})
    Store.get("settings")
    :ets.delete_all_objects(Store)
    AgentRegistry.reset()

    on_exit(fn ->
      for {key, value} <- saved, do: SettingsStore.put(key, value)
      if old, do: Application.put_env(:harness, :agent_model, old), else: Application.delete_env(:harness, :agent_model)
      :ets.delete_all_objects(Store)
      AgentRegistry.reset()
    end)

    :ok
  end

  test "defaults to the standing Codex model, never another provider" do
    assert %{"enabled" => false, "agent" => "codex", "model" => "gpt-6-astra"} = Insights.settings()
    assert :ok = Selection.validate(Insights.settings())
    Application.delete_env(:harness, :agent_model)
    assert Insights.settings()["model"] == nil
    assert Insights.status()["selection_error"] == "model_required"
  end

  test "disabled agents, unavailable models and runtime blocks fail without changing explicit settings" do
    assert :ok = Insights.configure(Insights.settings())
    chosen = Insights.settings()
    assert {:error, :unsupported_observer} = Selection.validate(%{"agent" => "cursor", "model" => "any"})
    assert {:error, :model_unavailable} = Insights.configure(Map.put(chosen, "model", "missing"))
    assert :ok = ModelAvailability.record_block(:codex, "gpt-6-astra", reason: "test")
    assert {:error, :model_unavailable} = Selection.validate(chosen)
    assert :ok = ModelAvailability.clear_block(:codex, "gpt-6-astra")
    assert :ok = AgentRegistry.mark_unavailable(Codex, :quota)
    assert {:error, :agent_unavailable} = Selection.validate(chosen)
    assert :ok = AgentRegistry.mark_available(Codex)
    assert :ok = Settings.set_enabled(:codex, false, "test")
    assert {:error, :agent_disabled} = Selection.validate(chosen)
    refute Enum.any?(Selection.choices(), &(&1.agent == "codex"))
    assert Insights.settings() == chosen
  end

  test "an explicit enabled Claude selection survives later default changes" do
    assert :ok = Settings.set_enabled(:claude, true, "test")
    model = List.first(ModelAvailability.list_available_ids(:claude))
    assert is_binary(model)
    chosen = Map.merge(Insights.settings(), %{"agent" => "claude", "model" => model})
    assert :ok = Insights.configure(chosen)
    Application.put_env(:harness, :agent_model, codex: "different-standing-model")
    assert Insights.settings() == chosen
    assert :ok = Settings.set_enabled(:claude, false, "test")
    assert Insights.settings() == chosen
    assert Insights.status()["selection_error"] == "agent_disabled"
  end
end
