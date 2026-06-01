defmodule Harness.Benchmark.Eval.Otp.LatchTest do
  use ExUnit.Case, async: true

  alias Harness.Benchmark.Eval.Otp.Latch

  setup do
    name = :"bench_latch_#{System.unique_integer([:positive])}"
    {:ok, pid} = Latch.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: :gen_statem.stop(pid, :normal, :infinity) end)
    %{pid: pid}
  end

  test "toggle alternates open and closed", %{pid: pid} do
    assert :open = :gen_statem.call(pid, :state)
    :gen_statem.cast(pid, :toggle)
    assert :closed = :gen_statem.call(pid, :state)
    :gen_statem.cast(pid, :toggle)
    assert :open = :gen_statem.call(pid, :state)
  end

  test ":set forces a state", %{pid: pid} do
    :gen_statem.cast(pid, {:set, :closed})
    assert :closed = :gen_statem.call(pid, :state)
  end
end
