defmodule Harness.Benchmark.Eval.Otp.SupervisedCounterTest do
  use ExUnit.Case, async: true

  alias Harness.Benchmark.Eval.Otp.SupervisedCounter

  setup do
    name = :"bench_counter_#{System.unique_integer([:positive])}"
    child = :"bench_child_#{System.unique_integer([:positive])}"
    {:ok, _sup} = start_supervised({SupervisedCounter, name: name, child_name: child})
    %{name: name, child: child}
  end

  test "increment returns successive counts", %{child: child} do
    assert 1 = SupervisedCounter.increment(child)
    assert 2 = SupervisedCounter.increment(child)
  end

  test "killed child restarts with zero count", %{child: child} do
    assert 1 = SupervisedCounter.increment(child)
    Process.exit(Process.whereis(child), :kill)
    Process.sleep(50)
    assert 1 = SupervisedCounter.increment(child)
  end
end
