defmodule Harness.DepFreshnessStore.MemoryTest do
  use ExUnit.Case, async: true

  alias Harness.DepFreshness.Row
  alias Harness.DepFreshness.Snapshot
  alias Harness.DepFreshnessStore
  alias Harness.DepFreshnessStore.Memory, as: Store
  alias Harness.DepFreshnessStore.Postgres, as: PostgresStore

  setup do
    prev = Application.get_env(:harness, :dep_freshness_store)
    Application.put_env(:harness, :dep_freshness_store, {Store, scope: :memory_test})

    on_exit(fn -> Application.put_env(:harness, :dep_freshness_store, prev) end)

    :ok
  end

  test "records and fetches the latest snapshot for a project" do
    store = DepFreshnessStore.configured()

    snapshot =
      Snapshot.build("demo", "elixir", [
        %Row{name: "req", current_version: "0.6.1", latest_version: "0.6.2", constraint_allowed: true}
      ])

    assert :ok = DepFreshnessStore.record_snapshot(snapshot, store)
    assert {:ok, fetched} = DepFreshnessStore.fetch_snapshot("demo", store)
    assert fetched.outdated_count == 1
    assert hd(fetched.rows).name == "req"

    replacement =
      Snapshot.build("demo", "elixir", [
        %Row{name: "req", current_version: "0.6.2", latest_version: "0.6.2", constraint_allowed: true}
      ])

    assert :ok = DepFreshnessStore.record_snapshot(replacement, store)
    assert {:ok, updated} = DepFreshnessStore.fetch_snapshot("demo", store)
    assert updated.outdated_count == 0
  end

  test "facade dispatches to a bare module store" do
    snapshot = Snapshot.build("bare", "elixir", [])

    assert :ok = DepFreshnessStore.record_snapshot(snapshot, Store)
    assert {:ok, fetched} = DepFreshnessStore.fetch_snapshot("bare", Store)
    assert fetched.project_name == "bare"
    assert {:ok, [listed]} = DepFreshnessStore.list_snapshots([], Store)
    assert listed.project_name == "bare"
  end

  test "facade default arguments use the configured store" do
    snapshot = Snapshot.build("defaulted", "elixir", [])

    assert :ok = DepFreshnessStore.record_snapshot(snapshot)
    assert {:ok, fetched} = DepFreshnessStore.fetch_snapshot("defaulted")
    assert fetched.project_name == "defaulted"
    assert {:ok, [_listed]} = DepFreshnessStore.list_snapshots([])
  end

  test "disabled store accepts record requests without persisting" do
    snapshot = Snapshot.build("disabled", "elixir", [])

    assert :ok = DepFreshnessStore.record_snapshot(snapshot, false)
  end

  test "configured/0 follows repo_enabled when no explicit store is set" do
    prior_store = Application.get_env(:harness, :dep_freshness_store)
    prior_repo_enabled = Application.get_env(:harness, :repo_enabled)

    Application.delete_env(:harness, :dep_freshness_store)
    Application.put_env(:harness, :repo_enabled, false)
    assert DepFreshnessStore.configured() == {Store, []}

    Application.put_env(:harness, :repo_enabled, true)
    assert DepFreshnessStore.configured() == {PostgresStore, []}

    restore(:dep_freshness_store, prior_store)
    restore(:repo_enabled, prior_repo_enabled)
  end

  test "list_snapshots/1 filters by project name" do
    store = DepFreshnessStore.configured()

    assert :ok =
             DepFreshnessStore.record_snapshot(
               Snapshot.build("alpha", "elixir", []),
               store
             )

    assert :ok =
             DepFreshnessStore.record_snapshot(
               Snapshot.build("beta", "elixir", []),
               store
             )

    assert {:ok, [only_alpha]} = DepFreshnessStore.list_snapshots([project_name: "alpha"], store)
    assert only_alpha.project_name == "alpha"
  end

  @spec restore(atom(), term()) :: :ok
  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)
end
