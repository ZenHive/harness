defmodule HarnessTest do
  use ExUnit.Case

  doctest Harness

  test "application starts the supervisor" do
    assert Process.whereis(Harness.Supervisor)
  end

  test "version/0 returns the application version" do
    assert Harness.version() =~ ~r/^\d+\.\d+\.\d+/
  end
end
