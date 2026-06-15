defmodule Harness.Notification.FileSinkTest do
  @moduledoc """
  Append-only JSONL witness sink: configured path appends one line per event;
  unconfigured path and malformed targets are failure-isolated no-ops.
  """
  # async: false because tests mutate FileSink's global application env config.
  use ExUnit.Case, async: false

  alias Harness.Notification.Event
  alias Harness.Notification.FileSink

  @moduletag :tmp_dir

  setup do
    on_exit(fn -> Application.delete_env(:harness, FileSink) end)
    :ok
  end

  defp event do
    %Event{
      type: :settled,
      task_id: "42",
      run_id: "run-9",
      project: "harness",
      branch: "harness/run-9",
      land_attempt: 1,
      outcome: %{state: :done, reason: :approved, passed: true}
    }
  end

  describe "notify/1 — configured path" do
    test "appends one JSON line per event", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "settled.jsonl")
      Application.put_env(:harness, FileSink, path: path)

      assert :ok = FileSink.notify(event())
      assert :ok = FileSink.notify(%{event() | type: :landed, outcome: "abc123"})

      lines = path |> File.read!() |> String.split("\n", trim: true)
      assert length(lines) == 2

      first = Jason.decode!(hd(lines))
      assert first["type"] == "settled"
      assert first["task_id"] == "42"
      assert first["run_id"] == "run-9"
      assert first["project"] == "harness"
      assert first["branch"] == "harness/run-9"
      assert first["land_attempt"] == 1
      assert first["outcome"]["state"] == "done"
      assert first["summary"] == "settled run run-9 task 42: done/approved"
      assert is_binary(first["ts"])
    end
  end

  describe "notify/1 — unconfigured is a no-op" do
    test "no :path configured returns :ok and writes nothing", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "absent.jsonl")
      Application.delete_env(:harness, FileSink)

      assert :ok = FileSink.notify(event())
      refute File.exists?(path)
    end

    test "a blank :path is treated as unconfigured" do
      Application.put_env(:harness, FileSink, path: "")
      assert :ok = FileSink.notify(event())
    end
  end

  describe "notify/1 — failure isolation" do
    test "a malformed path is rescued and returns :ok" do
      Application.put_env(:harness, FileSink, path: "/dev/null/not-a-directory/settled.jsonl")
      assert :ok = FileSink.notify(event())
    end
  end
end
