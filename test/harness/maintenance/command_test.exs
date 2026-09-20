defmodule Harness.Maintenance.CommandTest do
  use ExUnit.Case, async: true

  alias Harness.Maintenance.Command

  test "fast process exits preserve output without terminating the caller" do
    for _ <- 1..20 do
      assert {"evidence", 0} = Command.run("/bin/sh", ["-c", "printf evidence"], timeout: 1000, stderr_to_stdout: true)
    end
  end

  test "deadline terminates a process tree and reports timeout" do
    assert {"", :timeout} = Command.run("/bin/sh", ["-c", "sleep 10"], timeout: 20, stderr_to_stdout: true)
  end
end
