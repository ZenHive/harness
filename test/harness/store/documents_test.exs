defmodule Harness.Store.DocumentsTest do
  use ExUnit.Case, async: false

  alias Harness.Insights.Store, as: Insights
  alias Harness.Maintenance.Store, as: Maintenance

  test "stores isolate identical IDs, retain writers' data and paginate filtered revisions" do
    kind = Ecto.UUID.generate()
    id = kind <> "/a"
    other = kind <> "/b"
    first = %{"id" => id, "projects" => ["a", "b"]}
    second = %{"id" => other, "projects" => ["a"]}

    assert Insights.get(id) == nil
    assert Maintenance.get(id) == nil

    for store <- [Insights, Maintenance] do
      writer = Task.async(fn -> store.put_many([{id, kind, first}, {other, kind, second}]) end)
      assert Task.await(writer) == :ok
      assert store.get(id) == first
      assert store.list(kind, 0, 100) == [second, first]
      assert store.list(kind, 1, 1) == [first]
      assert store.list(kind, 2, 1) == []
      assert store.list(kind, 0, 100, %{"projects" => ["a", "b"]}) == [first]
      assert store.list(kind, 0, 100, %{"missing" => ["a"]}) == []
      assert store.put_many([]) == :ok
      assert_raise FunctionClauseError, fn -> store.list(kind, -1, 1) end
      assert_raise FunctionClauseError, fn -> store.list(kind, 0, 0) end
      assert_raise FunctionClauseError, fn -> store.list(kind, 0, 101) end
    end

    assert Insights.put_many([{id, kind, %{"updated" => true}}]) == :ok
    assert Insights.get(id) == %{"updated" => true}
    assert Maintenance.get(id) == first
    assert Insights.list(kind, 0, 1) == [%{"updated" => true}]
  end

  test "each store owns a separate lock and releases it after failure" do
    parent = self()

    owner =
      Task.async(fn ->
        Insights.serialized(fn ->
          send(parent, :locked)

          receive do
            :release -> :released
          end
        end)
      end)

    assert_receive :locked
    refute :global.set_lock({Insights, self()}, [node()], 0)
    assert Maintenance.serialized(fn -> :independent end) == :independent
    send(owner.pid, :release)
    assert Task.await(owner) == :released

    assert_raise RuntimeError, "failure", fn ->
      Insights.serialized(fn -> raise "failure" end)
    end

    contender =
      Task.async(fn ->
        acquired = :global.set_lock({Insights, self()}, [node()], 0)
        :global.del_lock({Insights, self()}, [node()])
        acquired
      end)

    assert Task.await(contender)
  end
end
