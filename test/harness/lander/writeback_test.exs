defmodule Harness.Lander.WritebackTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Harness.AgentAdapter.Claude
  alias Harness.Lander.Writeback
  alias Harness.ResultStore
  alias Harness.ResultStore.Memory
  alias Harness.Run.LogRecord

  setup do
    store = {Memory, scope: {:writeback_test, self(), System.unique_integer([:positive])}}
    previous = Application.get_env(:harness, :result_store)
    Application.put_env(:harness, :result_store, store)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:harness, :result_store)
      else
        Application.put_env(:harness, :result_store, previous)
      end

      Memory.reset(elem(store, 1))
    end)

    record = %LogRecord{
      batch_id: "b",
      run_id: "run-wb",
      task_id: "1",
      task_ids: ["1", "2"],
      adapter: Claude,
      state: :done,
      reason: :approved,
      verdict: :approve,
      duration_ms: 1
    }

    assert :ok = ResultStore.record_run(record)
    {:ok, request: %{run_id: "run-wb", task_id: "1", task_ids: ["1", "2"], reviewer: :codex}}
  end

  test "rebuilds member progress when the stored map has no task ids", %{request: request} do
    assert :ok = ResultStore.put_roadmap_writeback("run-wb", %{})
    assert {:ok, progress} = Writeback.prepare(request)
    assert progress["task_ids"] == ["1", "2"]
    assert progress["status"] == "pending"
    assert progress["reviewer"] == "codex"
  end

  test "skips completed members and retries only the unfinished ones", %{request: request} do
    parent = self()

    write = fn id ->
      send(parent, {:write, id})
      if id == "2", do: {:error, :denied}, else: :ok
    end

    assert {:error, {:roadmap_writeback_failed, "2", :denied}} = Writeback.complete(request, write)
    assert_received {:write, "1"}
    assert_received {:write, "2"}
    refute_received {:write, _}

    assert {:ok, record} = ResultStore.fetch_run_record("run-wb")
    assert record.roadmap_writeback["completed_task_ids"] == ["1"]
    assert record.roadmap_writeback["status"] == "pending"

    assert :ok =
             Writeback.complete(request, fn id ->
               send(parent, {:retry, id})
               :ok
             end)

    assert_received {:retry, "2"}
    refute_received {:retry, "1"}
    assert {:ok, done} = ResultStore.fetch_run_record("run-wb")
    assert done.roadmap_writeback["status"] == "complete"
    assert done.roadmap_writeback["completed_task_ids"] == ["1", "2"]
  end
end
