defmodule Harness.Store.DocumentsPostgresTest do
  use Harness.DataCase, async: false

  alias Harness.Insights.Store, as: Insights
  alias Harness.Maintenance.Store, as: Maintenance

  @moduletag :integration

  setup do
    previous = Application.get_env(:harness, :repo_enabled)
    Application.put_env(:harness, :repo_enabled, true)
    on_exit(fn -> Application.put_env(:harness, :repo_enabled, previous) end)
  end

  test "persistent stores isolate IDs, filter pages and roll back failed batches" do
    id = Ecto.UUID.generate()
    kind = Ecto.UUID.generate()

    for {store, lock} <- [{Insights, 443}, {Maintenance, 444}] do
      data = %{"owner" => inspect(store), "projects" => ["one", "two"]}
      assert store.persistent?()
      assert store.get(id) == nil
      assert store.put_many([{id, kind, data}]) == :ok
      assert store.get(id) == data
      assert store.list(kind, 0, 1, %{"projects" => ["two"]}) == [data]
      assert store.list(kind, 1, 1) == []
      assert store.list(kind, 0, 1, %{"projects" => ["absent"]}) == []
      assert store.serialized(fn -> :held end) == :held

      assert_raise RuntimeError, "release lock", fn ->
        store.serialized(fn -> raise "release lock" end)
      end

      assert %{rows: [[false]]} =
               Repo.query!(
                 "SELECT EXISTS (SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid() AND classid = $1 AND objid = 1)",
                 [lock]
               )

      assert_raise Postgrex.Error, fn ->
        store.put_many([{id, kind, %{"changed" => true}}, {nil, kind, %{}}])
      end

      assert store.get(id) == data
    end

    assert Insights.put_many([{id, kind, %{"updated" => true}}]) == :ok
    assert Insights.get(id) == %{"updated" => true}
    assert Maintenance.get(id)["owner"] == inspect(Maintenance)
  end
end
