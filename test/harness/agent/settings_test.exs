defmodule Harness.Agent.SettingsTest do
  @moduledoc """
  Unit coverage for `Harness.Agent.Settings` — operator agent enablement and
  reviewer eligibility, read from and written to the one Postgres settings store
  (the in-memory test backend stands in for Postgres here).

  `async: false` — shares the global test settings store scope, reset per test.
  """

  use ExUnit.Case, async: false

  alias Harness.Agent.Settings
  alias Harness.Test.SettingsStoreMemory

  @scope :test_default

  setup do
    SettingsStoreMemory.reset(scope: @scope)

    on_exit(fn ->
      SettingsStoreMemory.reset(scope: @scope)
    end)

    :ok
  end

  describe "enable/disable" do
    test "agents are enabled by absence" do
      assert Settings.enabled?(:claude)
      refute Settings.disabled?(:claude)
      assert Settings.disabled_agents() == []
    end

    test "set_enabled(false) disables and the choice survives a restart" do
      assert :ok = Settings.set_enabled(:cursor, false, "test")
      assert Settings.disabled?(:cursor)
      refute Settings.enabled?(:cursor)

      # No app-env cache to clear: the store is the source of truth, so a fresh
      # read (as a restarted node would do) still sees the persisted flip.
      assert Settings.disabled?(:cursor)
      assert Settings.disabled_agents() == [:cursor]
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

  describe "ephemeral store" do
    test "with repo disabled, a flip is a no-op and reads stay at the default" do
      prior = Application.get_env(:harness, :settings_store)
      Application.put_env(:harness, :settings_store, false)
      on_exit(fn -> restore_env(:settings_store, prior) end)

      assert :ok = Settings.set_enabled(:claude, false, "test")
      # The no-op store discards the write; the read falls back to the default.
      assert Settings.enabled?(:claude)
      assert Settings.disabled_agents() == []
    end
  end

  describe "reviewer eligibility" do
    test "seeds ineligibility from the in-code default before any override" do
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

    test "set_reviewer_eligible(false) survives a restart" do
      assert :ok = Settings.set_reviewer_eligible(:codex, false, "test")
      assert Settings.reviewer_ineligible?(:codex)

      # A fresh read (restarted node) still sees the persisted ineligibility.
      assert Settings.reviewer_ineligible?(:codex)
    end

    test "a set_enabled toggle does not freeze the reviewer seed into the store" do
      # Disabling an implementer is not a reviewer override, so the persisted
      # record must not materialize the [:pi] seed.
      assert :ok = Settings.set_enabled(:cursor, false, "test")
      assert Settings.reviewer_ineligible_agents() == [:pi]
    end

    test "a persisted empty set makes a seeded agent eligible and overrides the config seed" do
      assert :ok = Settings.set_reviewer_eligible(:pi, true, "test")
      assert Settings.reviewer_ineligible_agents() == []
      assert Settings.reviewer_eligible?(:pi)

      # A fresh read (restarted node) still honours the persisted empty set.
      assert Settings.reviewer_eligible?(:pi)
      assert Settings.reviewer_ineligible_agents() == []
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:harness, key)
  defp restore_env(key, value), do: Application.put_env(:harness, key, value)
end
