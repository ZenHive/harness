defmodule Harness.DepFreshnessStore.MemoryTest do
  use ExUnit.Case, async: true

  alias Harness.DepFreshness.Row
  alias Harness.DepFreshness.Snapshot
  alias Harness.DepFreshnessStore
  alias Harness.DepFreshnessStore.Memory, as: Store

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
end
