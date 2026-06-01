defmodule Harness.Benchmark.Eval.Elixir.TreeWalkTest do
  use ExUnit.Case, async: true

  alias Harness.Benchmark.Eval.Elixir.TreeWalk

  test "walk/1 returns empty for nil" do
    assert TreeWalk.walk(nil) == []
  end

  test "walk/1 visits parent before children" do
    tree = %{value: 1, children: [%{value: 2, children: [%{value: 3}]}, %{value: 4}]}
    assert TreeWalk.walk(tree) == [1, 2, 3, 4]
  end
end
