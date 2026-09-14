defmodule Harness.Cron.UnroutableNoticeTest do
  # async: false because the store is a singleton GenServer shared across tests.
  use ExUnit.Case, async: false

  alias Harness.Cron.UnroutableNotice

  setup do
    UnroutableNotice.reset()
    on_exit(&UnroutableNotice.reset/0)
    :ok
  end

  test "the first sighting of an entry is fresh, a repeat is not" do
    assert [{"1", "human"}] = UnroutableNotice.fresh("proj", [{"1", "human"}])
    assert [] = UnroutableNotice.fresh("proj", [{"1", "human"}])
  end

  test "only the entries new to the set come back, in the order given" do
    assert [{"1", "human"}] = UnroutableNotice.fresh("proj", [{"1", "human"}])

    assert [{"2", nil}, {"3", "human"}] =
             UnroutableNotice.fresh("proj", [{"2", nil}, {"1", "human"}, {"3", "human"}])
  end

  test "a changed assignee is a new fact and announces again" do
    assert [{"1", "human"}] = UnroutableNotice.fresh("proj", [{"1", "human"}])
    assert [{"1", nil}] = UnroutableNotice.fresh("proj", [{"1", nil}])
  end

  test "an entry that leaves the set is forgotten, so a return announces again" do
    assert [{"1", "human"}] = UnroutableNotice.fresh("proj", [{"1", "human"}])
    assert [{"2", "human"}] = UnroutableNotice.fresh("proj", [{"2", "human"}])
    assert [{"1", "human"}] = UnroutableNotice.fresh("proj", [{"1", "human"}])
  end

  test "an empty set forgets the project" do
    assert [{"1", "human"}] = UnroutableNotice.fresh("proj", [{"1", "human"}])
    assert [] = UnroutableNotice.fresh("proj", [])
    assert [{"1", "human"}] = UnroutableNotice.fresh("proj", [{"1", "human"}])
  end

  test "projects do not share a notice set" do
    assert [{"1", "human"}] = UnroutableNotice.fresh("a", [{"1", "human"}])
    assert [{"1", "human"}] = UnroutableNotice.fresh("b", [{"1", "human"}])
    assert [] = UnroutableNotice.fresh("a", [{"1", "human"}])
  end

  test "reset forgets everything" do
    assert [{"1", "human"}] = UnroutableNotice.fresh("proj", [{"1", "human"}])
    assert :ok = UnroutableNotice.reset()
    assert [{"1", "human"}] = UnroutableNotice.fresh("proj", [{"1", "human"}])
  end
end
