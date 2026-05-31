defmodule Harness.Notification.CommandSinkTest do
  @moduledoc """
  The shipped sakshi sink: execs an operator-configured command with the event
  flattened into `HARNESS_NOTIFY_*` env vars; an unconfigured command is a no-op.
  """
  use ExUnit.Case, async: false

  alias Harness.Notification.CommandSink
  alias Harness.Notification.Event

  @moduletag :tmp_dir

  setup do
    on_exit(fn -> Application.delete_env(:harness, CommandSink) end)
    :ok
  end

  # Writes a shell script that dumps the HARNESS_NOTIFY_* env into `out_file`,
  # one KEY=VALUE per line, then returns its path.
  defp recording_script(tmp_dir, out_file) do
    script = Path.join(tmp_dir, "notify.sh")
    body = "#!/bin/sh\nenv | grep '^HARNESS_NOTIFY_' | sort > '#{out_file}'\n"
    File.write!(script, body)
    File.chmod!(script, 0o755)
    script
  end

  defp event do
    %Event{
      type: :post_merge_red,
      task_id: "101",
      run_id: "run-9",
      project: "harness",
      branch: "harness/run-9",
      land_attempt: 2,
      outcome: "ignored-by-summary-path"
    }
  end

  describe "notify/1 — configured command" do
    test "runs the command with the event in HARNESS_NOTIFY_* env vars", %{tmp_dir: tmp_dir} do
      out_file = Path.join(tmp_dir, "env.txt")
      script = recording_script(tmp_dir, out_file)
      Application.put_env(:harness, CommandSink, command: script)

      assert :ok = CommandSink.notify(event())

      recorded = File.read!(out_file)
      assert recorded =~ "HARNESS_NOTIFY_TYPE=post_merge_red"
      assert recorded =~ "HARNESS_NOTIFY_TASK_ID=101"
      assert recorded =~ "HARNESS_NOTIFY_RUN_ID=run-9"
      assert recorded =~ "HARNESS_NOTIFY_PROJECT=harness"
      assert recorded =~ "HARNESS_NOTIFY_BRANCH=harness/run-9"
      assert recorded =~ "HARNESS_NOTIFY_LAND_ATTEMPT=2"
      assert recorded =~ "HARNESS_NOTIFY_SUMMARY=post-merge red on task 101"
    end

    test "extra args from config are passed through to the command", %{tmp_dir: tmp_dir} do
      out_file = Path.join(tmp_dir, "args.txt")
      script = Path.join(tmp_dir, "args.sh")
      File.write!(script, "#!/bin/sh\nprintf '%s\\n' \"$@\" > '#{out_file}'\n")
      File.chmod!(script, 0o755)
      Application.put_env(:harness, CommandSink, command: script, args: ["--urgent", "topic"])

      assert :ok = CommandSink.notify(%{event() | type: :landed, outcome: "abc123"})

      assert out_file |> File.read!() |> String.split("\n", trim: true) == ["--urgent", "topic"]
    end
  end

  describe "notify/1 — unconfigured is a no-op" do
    test "no :command configured returns :ok and runs nothing" do
      Application.delete_env(:harness, CommandSink)
      assert :ok = CommandSink.notify(event())
    end

    test "a non-binary :command is treated as unconfigured" do
      Application.put_env(:harness, CommandSink, command: :not_a_string)
      assert :ok = CommandSink.notify(event())
    end
  end

  describe "notify/1 — failure isolation" do
    test "a command that cannot be executed is rescued and returns :ok", %{tmp_dir: tmp_dir} do
      Application.put_env(:harness, CommandSink, command: Path.join(tmp_dir, "does-not-exist"))
      assert :ok = CommandSink.notify(event())
    end
  end
end
