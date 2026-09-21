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

  test "newest-first ordering follows write time, not %DateTime{} term order" do
    # Erlang term order compares maps field-by-field in atom order — day, hour,
    # MICROSECOND, minute, month, second — so sorting on the %DateTime{} struct
    # ranks a stamp by its sub-second part before its second. These two rows sit
    # one second apart with inverted sub-second parts, which is exactly where the
    # struct comparison and chronology disagree. Written straight into the public
    # ETS table because put_many/1 stamps rows with DateTime.utc_now/0 and a test
    # cannot place a write on either side of a second boundary without sleeping.
    kind = Ecto.UUID.generate()
    _ = Insights.get(kind)
    at = DateTime.utc_now()
    older = %{at | second: 10, microsecond: {900_000, 6}}
    newer = %{at | second: 11, microsecond: {100_000, 6}}
    assert DateTime.before?(older, newer)

    # Sorted by raw term order the OLDER stamp comes first — that inversion is
    # the premise of this test. Expressed through Enum.sort/2 rather than a
    # literal `older > newer` because Elixir 1.20's type checker warns on a
    # struct comparison, and the warning would be about the very behavior being
    # pinned here.
    assert Enum.sort([older, newer], :desc) == [older, newer]

    old_doc = %{"id" => "older"}
    new_doc = %{"id" => "newer"}

    true =
      :ets.insert(Insights, [
        {"older", kind, old_doc, older},
        {"newer", kind, new_doc, newer}
      ])

    assert Insights.list(kind, 0, 100) == [new_doc, old_doc]
    assert Insights.list(kind, 0, 1) == [new_doc]
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
