defmodule Mix.Tasks.Harness.Worktree.ReclaimTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Harness.Worktree.Reclaim

  test "run/1 dry-runs by default" do
    output = capture_io(fn -> assert :ok = Reclaim.run([]) end)

    assert output =~ "harness worktree reclaim (dry-run)"
  end
end
