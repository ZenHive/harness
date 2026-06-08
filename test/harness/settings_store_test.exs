defmodule Harness.SettingsStoreTest do
  use ExUnit.Case, async: false

  alias Harness.SettingsStore
  alias Harness.SettingsStore.Schema.Setting
  alias Harness.Test.SettingsStoreMemory

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

  describe "missing rows" do
    test "returns :not_found when no row exists for the key" do
      scope = unique_scope("no-legacy")
      on_exit(fn -> SettingsStoreMemory.reset(scope: scope) end)

      Application.put_env(:harness, :settings_store, {SettingsStoreMemory, scope: scope})

      assert :not_found = SettingsStore.fetch(:landing)
    end
  end

  test "Setting changeset accepts key and payload attrs" do
    attrs = %{key: "cron", payload: :erlang.term_to_binary(%{master_enabled: false})}

    assert %{valid?: true} = Setting.changeset(%Setting{}, attrs)
  end

  defp unique_scope(label), do: :"settings_store_#{label}_#{System.unique_integer([:positive])}"

  defp restore_env(prior) do
    Enum.each(prior, fn
      {key, nil} -> Application.delete_env(:harness, key)
      {key, value} -> Application.put_env(:harness, key, value)
    end)
  end
end
