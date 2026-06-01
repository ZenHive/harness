defmodule Harness.Benchmark.Eval.Genserver.AccumulatorTest do
  use ExUnit.Case, async: true

  alias Harness.Benchmark.Eval.Genserver.Accumulator

  setup do
    name = :"bench_acc_#{System.unique_integer([:positive])}"
    {:ok, _pid} = start_supervised({Accumulator, name: name})
    %{name: name}
  end

  test "casts add and call returns total", %{name: name} do
    :ok = Accumulator.cast(name, 3)
    :ok = Accumulator.cast(name, 5)
    assert 8 = Accumulator.total(name)
  end
end
