defmodule Harness.SettingsStoreTest do
  use ExUnit.Case, async: false

  alias Harness.SettingsStore
  alias Harness.SettingsStore.Schema.Setting
  alias Harness.Test.SettingsStoreMemory
  alias Harness.TermCodec

  setup do
    prior = %{
      repo_enabled: Application.get_env(:harness, :repo_enabled),
      settings_store: Application.get_env(:harness, :settings_store)
    }

    on_exit(fn -> restore_env(prior) end)

    :ok
  end

  describe "configured/0" do
    test "picks Postgres when repo_enabled and no override" do
      Application.put_env(:harness, :repo_enabled, true)
      Application.delete_env(:harness, :settings_store)

      assert {Harness.SettingsStore.Postgres, []} = SettingsStore.configured()
    end

    test "is the ephemeral no-op store when repo_enabled is false" do
      Application.put_env(:harness, :repo_enabled, false)
      Application.delete_env(:harness, :settings_store)

      assert SettingsStore.configured() == false
    end

    test "respects an explicit settings_store override" do
      Application.put_env(:harness, :settings_store, false)

      assert SettingsStore.configured() == false
    end
  end

  describe "ephemeral (false) store" do
    test "fetch is :not_found and put is a discarded :ok" do
      Application.put_env(:harness, :settings_store, false)

      assert :ok = SettingsStore.put(:agent, %{disabled: [:pi]})
      assert :not_found = SettingsStore.fetch(:agent)
      assert :not_found = SettingsStore.fetch("agent")
    end
  end

  describe "round-trip through a backend" do
    test "put then fetch returns the value (atom or binary key)" do
      scope = unique_scope("round-trip")
      Application.put_env(:harness, :settings_store, {SettingsStoreMemory, scope: scope})
      on_exit(fn -> SettingsStoreMemory.reset(scope: scope) end)

      record = %{disabled: [:codex]}
      assert :ok = SettingsStore.put(:agent, record)
      assert {:ok, ^record} = SettingsStore.fetch(:agent)
      assert {:ok, ^record} = SettingsStore.fetch("agent")
    end
  end

  describe "one-time legacy import" do
    test "imports a legacy term file on the first fetch of a missing key" do
      scope = unique_scope("legacy")
      root = tmp_root("legacy-import")
      on_exit(fn -> File.rm_rf(root) end)
      on_exit(fn -> SettingsStoreMemory.reset(scope: scope, legacy_root: root) end)

      File.mkdir_p!(root)
      legacy = %{master_enabled: true, project_autonomy: %{}, schedule: "0 */2 * * *"}
      assert :ok = TermCodec.write_file(Path.join(root, "cron_settings.term"), legacy)

      Application.put_env(:harness, :settings_store, {SettingsStoreMemory, scope: scope, legacy_root: root})

      # First fetch imports the legacy file and persists it.
      assert {:ok, ^legacy} = SettingsStore.fetch(:cron)
      # Subsequent fetch reads the persisted row (legacy file no longer consulted).
      File.rm!(Path.join(root, "cron_settings.term"))
      assert {:ok, ^legacy} = SettingsStore.fetch(:cron)
    end

    test "returns :not_found when no legacy file exists for the key" do
      scope = unique_scope("no-legacy")
      root = tmp_root("no-legacy")
      on_exit(fn -> File.rm_rf(root) end)
      on_exit(fn -> SettingsStoreMemory.reset(scope: scope, legacy_root: root) end)

      Application.put_env(:harness, :settings_store, {SettingsStoreMemory, scope: scope, legacy_root: root})

      assert :not_found = SettingsStore.fetch(:landing)
    end
  end

  test "Setting changeset accepts key and payload attrs" do
    attrs = %{key: "cron", payload: :erlang.term_to_binary(%{master_enabled: false})}

    assert %{valid?: true} = Setting.changeset(%Setting{}, attrs)
  end

  defp unique_scope(label), do: :"settings_store_#{label}_#{System.unique_integer([:positive])}"

  defp tmp_root(label) do
    Path.join(System.tmp_dir!(), "settings_store_#{label}_#{System.unique_integer([:positive])}")
  end

  defp restore_env(prior) do
    Enum.each(prior, fn
      {key, nil} -> Application.delete_env(:harness, key)
      {key, value} -> Application.put_env(:harness, key, value)
    end)
  end
end
