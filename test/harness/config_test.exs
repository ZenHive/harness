defmodule Harness.ConfigTest do
  @moduledoc """
  Unit coverage for `Harness.Config` (Task 167) — the declarative schema +
  read/write accessor for operator config.

  `async: false` — every assertion reads or mutates global `:harness` app env and
  the file-backed `Harness.SettingsStore` (isolated to a per-test tmp root via
  `:config_settings`), which would leak across parallel tests.
  """

  use ExUnit.Case, async: false

  alias Harness.Config
  alias Harness.Config.Entry
  alias Harness.SettingsStore

  setup do
    prior_run = Application.get_env(:harness, :run)
    prior_dashboard = Application.get_env(:harness, :dashboard)
    prior_dispatch = Application.get_env(:harness, :dispatch)
    prior_store = Application.get_env(:harness, :config_settings)

    # Isolate the persistence file to a throwaway root.
    root = Path.join(System.tmp_dir!(), "harness_config_#{System.unique_integer([:positive])}")
    Application.put_env(:harness, :config_settings, root: root)

    on_exit(fn ->
      restore(:run, prior_run)
      restore(:dashboard, prior_dashboard)
      restore(:dispatch, prior_dispatch)
      restore(:config_settings, prior_store)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  describe "schema/0" do
    test "every entry is a well-formed Entry with a known type" do
      types = ~w(duration_ms integer boolean string path float atom_list agent)a

      for %Entry{} = entry <- Config.schema() do
        assert is_binary(entry.section)
        assert is_binary(entry.label)
        assert entry.type in types
      end
    end

    test "no test-injection seam keys leak into the schema" do
      keys = Enum.map(Config.schema(), & &1.key)

      for seam <- [:roadmap_list, :run_starter, :run_supervisor] do
        refute seam in keys
        refute Enum.any?(keys, &match?({^seam, _}, &1))
      end
    end

    test "editable_entries/0 is exactly the ui_editable? subset" do
      assert Enum.all?(Config.editable_entries(), & &1.ui_editable?)
      assert Config.editable_entries() == Enum.filter(Config.schema(), & &1.ui_editable?)
      # The run timeouts are the editable core.
      labels = Enum.map(Config.editable_entries(), & &1.label)
      assert "lifetime_timeout" in labels
      assert "total_timeout" in labels
    end
  end

  describe "get/1" do
    test "returns the schema default when nothing overrides it" do
      Application.delete_env(:harness, :run)
      assert Config.get({:run, :lifetime_timeout}) == 5_400_000
      assert Config.get({:run, :total_timeout}) == nil
    end

    test "returns the live app-env value when set" do
      Application.put_env(:harness, :run, lifetime_timeout: 123)
      assert Config.get({:run, :lifetime_timeout}) == 123
    end

    test "raises ArgumentError on an unknown key" do
      assert_raise ArgumentError, ~r/unknown config key/, fn -> Config.get({:run, :nonexistent}) end
    end
  end

  describe "put/3" do
    test "validates, persists, and hot-applies an editable non-restart key", %{root: root} do
      assert :ok = Config.put({:run, :lifetime_timeout}, 99_000, "test")
      # Live cache updated immediately.
      assert Config.get({:run, :lifetime_timeout}) == 99_000
      # Persisted to the store file.
      assert File.exists?(Path.join(root, "harness_settings.term"))
    end

    test "accepts nil for a nullable duration (unbounded)" do
      assert :ok = Config.put({:run, :total_timeout}, nil, "test")
      assert Config.get({:run, :total_timeout}) == nil
    end

    test "rejects a non-editable key without mutating anything" do
      before = Application.get_env(:harness, :cron_polling)
      assert {:error, :not_editable} = Config.put({:cron_polling, :enabled}, true, "test")
      assert Application.get_env(:harness, :cron_polling) == before
    end

    test "rejects an unknown key" do
      assert {:error, :unknown_key} = Config.put({:run, :nope}, 1, "test")
    end

    test "rejects an invalid value (negative duration) without mutating" do
      Application.put_env(:harness, :run, lifetime_timeout: 5_400_000)
      assert {:error, :invalid_value} = Config.put({:run, :lifetime_timeout}, -1, "test")
      assert Config.get({:run, :lifetime_timeout}) == 5_400_000
    end

    test "persists a restart-required key but does NOT hot-apply it" do
      Application.put_env(:harness, :dashboard, port: 4018)
      assert :ok = Config.put({:dashboard, :port}, 4099, "test")
      # The live value is unchanged — applies only on the next boot via load_into_env/0.
      assert Config.get({:dashboard, :port}) == 4018
    end

    test "accepts an :agent-typed value in the implementer set and hot-applies it" do
      assert :ok = Config.put({:dispatch, :default_agent}, :cursor, "test")
      assert Config.get({:dispatch, :default_agent}) == :cursor
    end

    test "rejects an agent outside the implementer set without mutating" do
      Application.put_env(:harness, :dispatch, default_agent: :codex)
      assert {:error, :invalid_value} = Config.put({:dispatch, :default_agent}, :droid, "test")
      assert {:error, :invalid_value} = Config.put({:dispatch, :default_agent}, :human, "test")
      assert Config.get({:dispatch, :default_agent}) == :codex
    end
  end

  describe "dispatch default agent" do
    test "schema default is :codex — unassigned work avoids spending Claude tokens" do
      assert Config.get({:dispatch, :default_agent}) == :codex
    end

    test "dispatch_agents/0 is the implementer set, excluding :human" do
      agents = Config.dispatch_agents()
      assert :claude in agents and :codex in agents and :cursor in agents
      refute :human in agents
      refute :droid in agents
    end
  end

  describe "load_into_env/0" do
    test "seeds persisted overrides into app env on boot" do
      assert :ok = Config.put({:run, :lifetime_timeout}, 77_000, "test")

      # Simulate a restart: clear the live cache, reload from the persisted store.
      Application.delete_env(:harness, :run)
      assert :ok = Config.load_into_env()
      assert Config.get({:run, :lifetime_timeout}) == 77_000
    end

    test "seeds a restart-required override that put/3 deliberately withheld" do
      Application.put_env(:harness, :dashboard, port: 4018)
      assert :ok = Config.put({:dashboard, :port}, 4099, "test")
      assert Config.get({:dashboard, :port}) == 4018

      assert :ok = Config.load_into_env()
      assert Config.get({:dashboard, :port}) == 4099
    end

    test "an env var wins over a persisted override (env > persisted)" do
      assert :ok = Config.put({:dashboard, :port}, 4099, "test")
      System.put_env("HARNESS_DASHBOARD_PORT", "5000")
      on_exit(fn -> System.delete_env("HARNESS_DASHBOARD_PORT") end)

      Application.delete_env(:harness, :dashboard)
      assert :ok = Config.load_into_env()
      # The override is skipped because the env var is authoritative; app env is
      # left at its config/runtime value (here, unset → schema default).
      assert Config.get({:dashboard, :port}) == 4018
    end

    test "an override for a key no longer in the schema is ignored, not crashed" do
      # Seed the store directly with a stale key alongside a live one — a schema
      # that dropped a key must not crash load_into_env/0 on the orphan override.
      store_opts = [
        legacy_config_key: :config_settings,
        legacy_filename: "config_settings.term",
        default_root: "~/.harness"
      ]

      :ok = SettingsStore.put(:config, %{{:run, :gone_key} => 1, {:run, :lifetime_timeout} => 88_000}, store_opts)

      Application.delete_env(:harness, :run)
      assert :ok = Config.load_into_env()
      assert Config.get({:run, :lifetime_timeout}) == 88_000
    end
  end

  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)
end
