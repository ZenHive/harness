defmodule Harness.Maintenance.StoreTest do
  use ExUnit.Case, async: false

  alias Harness.Maintenance.Store

  test "ephemeral documents survive the writer and retain chronological pages" do
    id = Ecto.UUID.generate()
    task = Task.async(fn -> Store.put_many([{id, "store-test", %{"id" => id}}]) end)
    assert :ok = Task.await(task)
    assert Store.get(id) == %{"id" => id}
    assert [%{"id" => ^id}] = Store.list("store-test", 0, 1)
    assert Store.list("store-test", 0, 1, %{"projects" => ["absent"]}) == []
    refute Store.persistent?()
  end

  @tag :integration
  test "Postgres records survive repository restart and writes roll back atomically" do
    old = Application.get_env(:harness, :repo_enabled)
    Application.put_env(:harness, :repo_enabled, true)
    on_exit(fn -> Application.put_env(:harness, :repo_enabled, old) end)
    start_supervised!(Harness.Repo)
    id = Ecto.UUID.generate()
    assert :ok = Store.put_many([{id, "restart-test", %{"source_revision" => "abc", "model" => "pinned"}}])
    stop_supervised!(Harness.Repo)
    start_supervised!(Harness.Repo)
    assert Store.get(id) == %{"source_revision" => "abc", "model" => "pinned"}
    assert Store.persistent?()
    assert [%{"model" => "pinned"}] = Store.list("restart-test", 0, 1)
    assert :ok = Store.serialized(fn -> :ok end)

    assert_raise Postgrex.Error, fn ->
      Store.put_many([{id, "restart-test", %{"changed" => true}}, {nil, "invalid", %{}}])
    end

    assert Store.get(id)["model"] == "pinned"
  end
end
