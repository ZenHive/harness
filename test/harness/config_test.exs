defmodule Harness.ConfigTest do
  @moduledoc """
  Unit coverage for `Harness.Config` (Task 167) — the declarative schema +
  read/write accessor for operator config.

  `async: false` — every assertion reads or mutates global `:harness` app env and
  the single `Harness.SettingsStore` (isolated to a per-test in-memory scope),
  which would leak across parallel tests.
  """

  # async: false because tests read and mutate global :harness application env.
  use ExUnit.Case, async: false

  alias Harness.Config
  alias Harness.Config.Entry
  alias Harness.SettingsStore
  alias Harness.Test.SettingsStoreMemory

  @hours_per_day 24
  @default_transcript_retention_days 30
  @default_transcript_retention_ms to_timeout(hour: @hours_per_day) * @default_transcript_retention_days

  setup do
    prior_run = Application.get_env(:harness, :run)
    prior_run_records = Application.get_env(:harness, :run_records)
    prior_dashboard = Application.get_env(:harness, :dashboard)
    prior_dispatch = Application.get_env(:harness, :dispatch)
    prior_agent_model = Application.get_env(:harness, :agent_model)
    prior_reviewer_model = Application.get_env(:harness, :reviewer_model)
    prior_store = Application.get_env(:harness, :settings_store)

    # Isolate persistence to a throwaway in-memory scope.
    scope = :"config_test_#{System.unique_integer([:positive])}"

    Application.put_env(:harness, :settings_store, {SettingsStoreMemory, scope: scope})

    on_exit(fn ->
      restore(:run, prior_run)
      restore(:run_records, prior_run_records)
      restore(:dashboard, prior_dashboard)
      restore(:dispatch, prior_dispatch)
      restore(:agent_model, prior_agent_model)
      restore(:reviewer_model, prior_reviewer_model)
      restore(:settings_store, prior_store)
      SettingsStoreMemory.reset(scope: scope)
    end)

    {:ok, scope: scope}
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
    test "keeps agent process timeouts under the extracted package key" do
      assert [
               total_timeout: 1_800_000,
               idle_timeout: 300_000,
               progress_timeout: 300_000,
               terminate_grace_ms: 1_000
             ] = Application.fetch_env!(:harness_agent_adapter, :run)

      harness_run = Application.get_env(:harness, :run, [])
      refute Keyword.has_key?(harness_run, :total_timeout)
      refute Keyword.has_key?(harness_run, :idle_timeout)
      refute Keyword.has_key?(harness_run, :progress_timeout)
    end

    test "returns the schema default when nothing overrides it" do
      Application.delete_env(:harness, :run)
      assert Config.get({:run, :lifetime_timeout}) == 5_400_000
      assert Config.get({:run, :total_timeout}) == nil
      assert Config.get({:run_records, :transcript_retention_ms}) == @default_transcript_retention_ms
    end

    test "returns the live app-env value when set" do
      Application.put_env(:harness, :run, lifetime_timeout: 123)
      assert Config.get({:run, :lifetime_timeout}) == 123
    end

    test "raises ArgumentError on an unknown key" do
      assert_raise ArgumentError, ~r/unknown config key/, fn -> Config.get({:run, :nonexistent}) end
    end
  end

  describe "config MCP read surface" do
    test "list/0 projects schema entries and redacts secret values" do
      Application.put_env(:harness, Harness.Dashboard.Endpoint, secret_key_base: "super-secret")

      rows = Config.list()
      secret = Enum.find(rows, &(&1.key == "dashboard_endpoint.secret_key_base"))

      assert %{
               group: "Dashboard",
               label: "secret_key_base",
               key: "dashboard_endpoint.secret_key_base",
               value: "***",
               default: "***",
               editable: false,
               restart_required: true,
               env_var: "HARNESS_SECRET_KEY_BASE",
               secret: true
             } = secret
    end

    test "get_config/1 accepts a dotted key and returns the projected entry" do
      assert {:ok, %{key: "run.idle_timeout", value: nil, editable: true}} = Config.get_config("run.idle_timeout")
      assert {:ok, %{key: "agent_model.codex", value: nil}} = Config.get_config("agent_model.codex")
      assert {:error, {:unknown_key, "run.nope"}} = Config.get_config("run.nope")
    end
  end

  describe "put/3" do
    test "validates, persists, and hot-applies an editable non-restart key" do
      assert :ok = Config.put({:run, :lifetime_timeout}, 99_000, "test")
      # Live cache updated immediately.
      assert Config.get({:run, :lifetime_timeout}) == 99_000
      # Persisted to the store under the :config key.
      assert {:ok, overrides} = SettingsStore.fetch(:config)
      assert overrides[{:run, :lifetime_timeout}] == 99_000
    end

    test "accepts nil for a nullable duration (unbounded)" do
      assert :ok = Config.put({:run, :total_timeout}, nil, "test")
      assert Config.get({:run, :total_timeout}) == nil
    end

    test "rejects a non-editable key without mutating anything" do
      before = Application.get_env(:harness, :dashboard)
      assert {:error, :not_editable} = Config.put({:dashboard, :enabled}, false, "test")
      assert Application.get_env(:harness, :dashboard) == before
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
    test "schema default is :codex" do
      assert Config.get({:dispatch, :default_agent}) == :codex
    end

    test "dispatch_agents/0 is the implementer set, excluding :human" do
      agents = Config.dispatch_agents()
      assert :claude in agents and :codex in agents and :cursor in agents
      refute :human in agents
      refute :droid in agents
    end
  end

  describe "agent_model/1" do
    test "schema declares one editable :string model entry per implementer agent" do
      model_keys =
        Config.editable_entries()
        |> Enum.filter(&match?({:agent_model, _}, &1.key))
        |> Enum.map(&elem(&1.key, 1))

      assert Enum.sort(model_keys) == Enum.sort(Config.dispatch_agents())

      assert Enum.all?(Config.schema(), fn e ->
               match?({:agent_model, _}, e.key) == (e.section == "Agent models")
             end)
    end

    test "unset resolves to nil (CLI chooses its own default)" do
      assert Config.agent_model(:cursor) == nil
    end

    test "a put-through value resolves and hot-applies without restart" do
      assert :ok = Config.put({:agent_model, :cursor}, "claude-opus-4-8-thinking-high", "test")
      assert Config.agent_model(:cursor) == "claude-opus-4-8-thinking-high"
    end

    test "a blank value clears back to the CLI default (nil)" do
      assert :ok = Config.put({:agent_model, :codex}, "gpt-5.3-codex", "test")
      assert Config.agent_model(:codex) == "gpt-5.3-codex"
      assert :ok = Config.put({:agent_model, :codex}, "", "test")
      assert Config.agent_model(:codex) == nil
    end

    test "an agent outside the schema yields nil rather than raising" do
      assert Config.agent_model(:droid) == nil
    end

    test "put validates :string — a non-binary, non-nil value is rejected" do
      assert {:error, :invalid_value} = Config.put({:agent_model, :grok}, 42, "test")
      assert Config.agent_model(:grok) == nil
    end
  end

  describe "reviewer_model/1" do
    test "schema declares one editable reviewer :string model entry per implementer agent" do
      model_keys =
        Config.editable_entries()
        |> Enum.filter(&match?({:reviewer_model, _}, &1.key))
        |> Enum.map(&elem(&1.key, 1))

      assert Enum.sort(model_keys) == Enum.sort(Config.dispatch_agents())

      assert Enum.all?(Config.schema(), fn e ->
               match?({:reviewer_model, _}, e.key) == (e.section == "Reviewer models")
             end)
    end

    test "reviewer override wins and blank inherits the shared agent default" do
      assert :ok = Config.put({:agent_model, :cursor}, "composer-2.5-fast", "test")
      assert Config.reviewer_model(:cursor) == "composer-2.5-fast"

      assert :ok = Config.put({:reviewer_model, :cursor}, "claude-opus-4-8-thinking-high", "test")
      assert Config.reviewer_model(:cursor) == "claude-opus-4-8-thinking-high"

      assert :ok = Config.put({:reviewer_model, :cursor}, "", "test")
      assert Config.reviewer_model(:cursor) == "composer-2.5-fast"
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
      :ok = SettingsStore.put(:config, %{{:run, :gone_key} => 1, {:run, :lifetime_timeout} => 88_000})

      Application.delete_env(:harness, :run)
      assert :ok = Config.load_into_env()
      assert Config.get({:run, :lifetime_timeout}) == 88_000
    end
  end

  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)
end
