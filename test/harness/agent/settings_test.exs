defmodule Harness.Agent.SettingsTest do
  use ExUnit.Case, async: false

  alias Harness.Agent.Settings

  setup do
    prior_settings = Application.get_env(:harness, :agent_settings)
    prior_disabled = Application.get_env(:harness, :agent_disabled)
    prior_ineligible = Application.get_env(:harness, :agent_reviewer_ineligible)
    prior_exclude = Application.get_env(:harness, :reviewer_exclude)

    root = Path.join(System.tmp_dir!(), "harness_agent_settings_#{System.unique_integer([:positive])}")
    Application.put_env(:harness, :agent_settings, root: root)
    # Start each test from the config-seed fallback (no persisted override yet).
    Application.delete_env(:harness, :agent_reviewer_ineligible)
    Application.put_env(:harness, :reviewer_exclude, [:pi])

    on_exit(fn ->
      restore_env(:agent_settings, prior_settings)
      restore_env(:agent_disabled, prior_disabled)
      restore_env(:agent_reviewer_ineligible, prior_ineligible)
      restore_env(:reviewer_exclude, prior_exclude)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  describe "enable/disable" do
    test "agents are enabled by absence" do
      assert Settings.enabled?(:claude)
      refute Settings.disabled?(:claude)
      assert Settings.disabled_agents() == []
    end

    test "set_enabled(false) disables and persists across a reload" do
      assert :ok = Settings.set_enabled(:cursor, false, "test")
      assert Settings.disabled?(:cursor)
      refute Settings.enabled?(:cursor)

      # Simulate a restart: clear env, reload from the persisted file.
      Application.delete_env(:harness, :agent_disabled)
      assert :ok = Settings.load_into_env()
      assert Settings.disabled?(:cursor)
    end

    test "re-enabling removes the agent from the disabled set" do
      assert :ok = Settings.set_enabled(:grok, false, "test")
      assert Settings.disabled_agents() == [:grok]

      assert :ok = Settings.set_enabled(:grok, true, "test")
      assert Settings.disabled_agents() == []
      assert Settings.enabled?(:grok)
    end

    test "disabling is idempotent — no duplicate entries" do
      assert :ok = Settings.set_enabled(:pi, false, "test")
      assert :ok = Settings.set_enabled(:pi, false, "test")
      assert Settings.disabled_agents() == [:pi]
    end

    test "disabling one agent leaves the others enabled" do
      assert :ok = Settings.set_enabled(:codex, false, "test")

      assert Settings.disabled?(:codex)
      assert Settings.enabled?(:claude)
      assert Settings.enabled?(:cursor)
    end
  end

  describe "disabled store" do
    test "set_enabled still flips env but writes nothing" do
      Application.put_env(:harness, :agent_settings, false)

      assert :ok = Settings.set_enabled(:claude, false, "test")
      assert Settings.disabled?(:claude)

      # Nothing persisted: a reload from the (disabled) store is a no-op.
      assert :ok = Settings.load_into_env()
    end

    test "load_into_env is a no-op when no file exists yet", %{root: root} do
      refute File.exists?(Path.join(root, "agent_settings.term"))
      assert :ok = Settings.load_into_env()
      assert Settings.disabled_agents() == []
    end
  end

  describe "reviewer eligibility" do
    test "seeds ineligibility from the :reviewer_exclude config before any override" do
      refute Settings.reviewer_eligible?(:pi)
      assert Settings.reviewer_eligible?(:claude)
      assert Settings.reviewer_ineligible_agents() == [:pi]
    end

    test "an agent can be enabled as implementer yet ineligible as reviewer" do
      assert :ok = Settings.set_enabled(:pi, true, "test")
      assert :ok = Settings.set_reviewer_eligible(:pi, false, "test")

      assert Settings.enabled?(:pi)
      refute Settings.reviewer_eligible?(:pi)
    end

    test "set_reviewer_eligible(false) persists across a reload" do
      assert :ok = Settings.set_reviewer_eligible(:codex, false, "test")
      assert Settings.reviewer_ineligible?(:codex)

      # Simulate a restart: clear env, reload from the persisted file.
      Application.delete_env(:harness, :agent_reviewer_ineligible)
      assert :ok = Settings.load_into_env()
      assert Settings.reviewer_ineligible?(:codex)
    end

    test "a set_enabled toggle does not freeze the reviewer config seed into the file" do
      # Disabling an implementer is not a reviewer override, so persist/0 must
      # not materialize the [:pi] seed — the seed has to stay live on reload.
      assert :ok = Settings.set_enabled(:cursor, false, "test")

      Application.delete_env(:harness, :agent_reviewer_ineligible)
      assert :ok = Settings.load_into_env()

      assert Application.get_env(:harness, :agent_reviewer_ineligible) == nil
      assert Settings.reviewer_ineligible_agents() == [:pi]

      # The seed is genuinely live, not frozen: changing it now takes effect.
      Application.put_env(:harness, :reviewer_exclude, [:pi, :grok])
      assert Settings.reviewer_ineligible_agents() == [:pi, :grok]
    end

    test "a persisted empty set makes a seeded agent eligible and overrides the config seed" do
      assert :ok = Settings.set_reviewer_eligible(:pi, true, "test")
      assert Settings.reviewer_ineligible_agents() == []
      assert Settings.reviewer_eligible?(:pi)

      Application.delete_env(:harness, :agent_reviewer_ineligible)
      assert :ok = Settings.load_into_env()
      assert Settings.reviewer_eligible?(:pi)
      assert Settings.reviewer_ineligible_agents() == []
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:harness, key)
  defp restore_env(key, value), do: Application.put_env(:harness, key, value)
end
