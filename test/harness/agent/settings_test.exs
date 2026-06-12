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
    test "code seed disables claude, pi, and antigravity on first boot; others enabled by absence" do
      refute Settings.enabled?(:claude)
      assert Settings.disabled?(:claude)
      assert Settings.disabled?(:pi)
      assert Settings.disabled?(:antigravity)
      assert Settings.enabled?(:codex)
      assert Settings.enabled?(:cursor)
      assert Settings.enabled?(:grok)
      assert Settings.disabled_agents() == [:claude, :pi, :antigravity]
    end

    test "set_enabled(false) disables and the choice survives a restart" do
      assert :ok = Settings.set_enabled(:cursor, false, "test")
      assert Settings.disabled?(:cursor)
      refute Settings.enabled?(:cursor)

      # No app-env cache to clear: the store is the source of truth, so a fresh
      # read (as a restarted node would do) still sees the persisted flip.
      assert Settings.disabled?(:cursor)
      assert :cursor in Settings.disabled_agents()
    end

    test "re-enabling removes the agent from the disabled set" do
      assert :ok = Settings.set_enabled(:grok, false, "test")
      assert :grok in Settings.disabled_agents()

      assert :ok = Settings.set_enabled(:grok, true, "test")
      refute :grok in Settings.disabled_agents()
      assert Settings.enabled?(:grok)
    end

    test "disabling is idempotent — no duplicate entries" do
      assert :ok = Settings.set_enabled(:codex, false, "test")
      assert :ok = Settings.set_enabled(:codex, false, "test")
      assert Enum.count(Settings.disabled_agents(), &(&1 == :codex)) == 1
    end

    test "disabling one agent does not affect other non-seeded agents" do
      assert :ok = Settings.set_enabled(:codex, false, "test")

      assert Settings.disabled?(:codex)
      assert Settings.enabled?(:cursor)
      assert Settings.enabled?(:grok)
    end
  end

  describe "ephemeral store" do
    test "with repo disabled, a flip is a no-op and reads stay at the seed default" do
      prior = Application.get_env(:harness, :settings_store)
      Application.put_env(:harness, :settings_store, false)
      on_exit(fn -> restore_env(:settings_store, prior) end)

      assert :ok = Settings.set_enabled(:claude, false, "test")
      # The no-op store discards the write; the read falls back to the code seed.
      assert Settings.disabled?(:claude)
      assert Settings.disabled_agents() == [:claude, :pi, :antigravity]
    end
  end

  describe "reviewer eligibility" do
    test "seeds ineligibility from the in-code default before any override" do
      refute Settings.reviewer_eligible?(:pi)
      refute Settings.reviewer_eligible?(:claude)
      refute Settings.reviewer_eligible?(:grok)
      refute Settings.reviewer_eligible?(:antigravity)
      assert Settings.reviewer_eligible?(:codex)
      assert Settings.reviewer_eligible?(:cursor)
      assert Settings.reviewer_ineligible_agents() == [:grok, :claude, :antigravity, :pi]
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
      # record must not materialize the reviewer seed.
      assert :ok = Settings.set_enabled(:cursor, false, "test")
      assert Settings.reviewer_ineligible_agents() == [:grok, :claude, :antigravity, :pi]
    end

    test "a persisted override makes a seeded agent eligible and persisted value wins over seed" do
      assert :ok = Settings.set_reviewer_eligible(:pi, true, "test")
      refute :pi in Settings.reviewer_ineligible_agents()
      assert Settings.reviewer_eligible?(:pi)

      # A fresh read (restarted node) still honours the persisted override.
      assert Settings.reviewer_eligible?(:pi)
      # Other seeded agents remain ineligible via the persisted value.
      assert :grok in Settings.reviewer_ineligible_agents()
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:harness, key)
  defp restore_env(key, value), do: Application.put_env(:harness, key, value)
end
