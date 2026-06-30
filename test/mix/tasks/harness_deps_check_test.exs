defmodule Mix.Tasks.Harness.Deps.CheckTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Harness.Deps.Check

  @moduletag :tmp_dir

  test "raises for an unjustified over-tight dep constraint", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "mix.exs")
    File.write!(path, ~s({:plug, "~> 1.19.2"}))

    assert_raise Mix.Error, ~r/over-tight dependency constraints found/, fn ->
      Check.run([path])
    end
  end

  test "accepts a justified over-tight dep constraint", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "mix.exs")
    File.write!(path, ~s({:plug, "~> 1.19.2"} # tight pin: 1.20 changed parser behavior))

    assert :ok = Check.run([path])
  end
end
