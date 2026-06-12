defmodule Mix.Tasks.Harness.StatusTest do
  # async: false because it reads shared AgentRegistry and Run supervisor state.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Harness.Status

  test "run/1 prints a fleet snapshot to stdout" do
    output = capture_io(fn -> assert :ok = Status.run([]) end)

    assert output =~ "Harness fleet status"
  end
end
