defmodule Harness.Store.EtsScopeTest do
  use ExUnit.Case, async: true

  alias Harness.Store.EtsScope

  describe "ensure_table/1 create and lookup" do
    test "creates a named public set table owned by the calling process" do
      table = unique_table()

      assert :ok = EtsScope.ensure_table(table)
      assert :ets.info(table, :named_table) == true
      assert :ets.info(table, :type) == :set
      assert :ets.info(table, :protection) == :public
      assert :ets.info(table, :owner) == self()
    end

    test "a second create is a no-op and does not change ownership" do
      table = unique_table()

      assert :ok = EtsScope.ensure_table(table)
      assert :ok = EtsScope.ensure_table(table)
      assert :ets.info(table, :owner) == self()
    end

    test "concurrent creates all return :ok and leave a single owner" do
      table = unique_table()
      parent = self()
      release = make_ref()

      pids = Enum.map(1..8, fn _ -> race_create(table, release, parent) end)
      on_exit(fn -> Enum.each(pids, &Process.exit(&1, :kill)) end)

      Enum.each(pids, fn pid -> assert_receive {:ready, ^pid} end)
      Enum.each(pids, &send(&1, release))
      Enum.each(pids, fn pid -> assert_receive {:done, ^pid, :ok} end)

      owner = :ets.info(table, :owner)
      assert owner in pids
      assert :ets.info(table, :type) == :set
    end

    test "read returns empty when no row exists and the stored value after update" do
      table = unique_table()
      empty = %{n: 0}

      assert EtsScope.read(table, [scope: :a], empty) == empty

      assert :ok =
               EtsScope.update(table, [scope: :a], empty, fn state -> %{state | n: state.n + 1} end)

      assert EtsScope.read(table, [scope: :a], empty) == %{n: 1}
      assert EtsScope.read(table, [scope: :b], empty) == empty
    end

    test "scope lookup prefers :scope, then :root, then :default" do
      table = unique_table()

      assert EtsScope.scope(scope: :s, root: :r) == :s
      assert EtsScope.scope(root: :r) == :r
      assert EtsScope.scope([]) == :default

      assert :ok = EtsScope.update(table, [root: :r], :empty, fn _ -> :from_root end)
      assert EtsScope.read(table, [root: :r], :empty) == :from_root
      assert EtsScope.read(table, [], :empty) == :empty
    end

    test "reset deletes the scoped row and leaves the table" do
      table = unique_table()

      assert :ok = EtsScope.update(table, [scope: :a], :empty, fn _ -> :held end)
      assert :ok = EtsScope.reset(table, scope: :a)
      assert EtsScope.read(table, [scope: :a], :empty) == :empty
      refute :ets.info(table) == :undefined
    end
  end

  describe "table ownership on owner exit" do
    test "the named table is destroyed when the owning process exits" do
      table = unique_table()
      owner = hold_table(table)

      assert :ets.info(table, :owner) == owner
      assert EtsScope.read(table, [scope: :k], :empty) == :held

      ref = Process.monitor(owner)
      send(owner, :stop)
      assert_receive {:DOWN, ^ref, :process, ^owner, :normal}

      assert :ets.info(table) == :undefined
    end

    test "read recreates the table after the previous owner exits" do
      table = unique_table()
      owner = hold_table(table)

      ref = Process.monitor(owner)
      send(owner, :stop)
      assert_receive {:DOWN, ^ref, :process, ^owner, :normal}
      assert :ets.info(table) == :undefined

      assert EtsScope.read(table, [scope: :k], :empty) == :empty
      assert :ets.info(table, :owner) == self()
    end
  end

  @spec unique_table() :: atom()
  defp unique_table, do: :"ets_scope_#{System.unique_integer([:positive])}"

  @spec race_create(atom(), reference(), pid()) :: pid()
  defp race_create(table, release, parent) do
    spawn(fn ->
      send(parent, {:ready, self()})

      receive do
        ^release ->
          send(parent, {:done, self(), EtsScope.ensure_table(table)})

          receive do
            :stop -> :ok
          end
      end
    end)
  end

  @spec hold_table(atom()) :: pid()
  defp hold_table(table) do
    parent = self()

    owner =
      spawn(fn ->
        :ok = EtsScope.ensure_table(table)
        :ok = EtsScope.update(table, [scope: :k], :empty, fn _ -> :held end)
        send(parent, {:ready, self()})

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      if Process.alive?(owner), do: Process.exit(owner, :kill)
    end)

    assert_receive {:ready, ^owner}
    owner
  end
end
