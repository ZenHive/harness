defmodule Harness.Dashboard.RunFeedTest do
  use ExUnit.Case, async: true

  alias Harness.Dashboard.RunFeed
  alias Harness.Run.Status

  defp status(run_id, state) do
    %Status{run_id: run_id, task_id: "1", state: state}
  end

  describe "subscribe/0 + broadcast_update/1" do
    test "a subscriber receives non-terminal updates on the fleet topic" do
      assert :ok = RunFeed.subscribe()
      st = status("rf-1", :running)

      assert :ok = RunFeed.broadcast_update(st)
      assert_receive {:harness_run_update, ^st}
    end
  end

  describe "broadcast_settled/1" do
    test "a subscriber receives the terminal status" do
      assert :ok = RunFeed.subscribe()
      st = status("rf-2", :done)

      assert :ok = RunFeed.broadcast_settled(st)
      assert_receive {:harness_run_settled, ^st}
    end
  end

  describe "unsubscribe/0" do
    test "stops delivery after unsubscribe" do
      :ok = RunFeed.subscribe()
      :ok = RunFeed.unsubscribe()

      RunFeed.broadcast_update(status("rf-3", :running))
      refute_receive {:harness_run_update, _}, 100
    end
  end

  test "topic/0 is the stable fleet topic" do
    assert RunFeed.topic() == "harness:runs"
  end
end
