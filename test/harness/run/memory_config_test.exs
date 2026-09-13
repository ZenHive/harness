defmodule Harness.Run.MemoryConfigTest do
  use ExUnit.Case, async: false

  @variables ~w(HARNESS_NODE_MEM_LOWWATER_GB HARNESS_RUN_MEM_THRESHOLD_GB)

  setup do
    previous = Map.new(@variables, &{&1, System.get_env(&1)})
    Enum.each(@variables, &System.delete_env/1)
    on_exit(fn -> System.put_env(previous) end)
    :ok
  end

  test "runtime overrides independently configure headroom and the per-run cap" do
    System.put_env("HARNESS_NODE_MEM_LOWWATER_GB", "8")
    System.put_env("HARNESS_RUN_MEM_THRESHOLD_GB", "12")

    config = run_config()
    assert config[:mem_lowwater_kb] == 8 * 1024 * 1024
    assert config[:mem_threshold_kb] == 12 * 1024 * 1024
    assert config[:max_hold_timeout] == 1_800_000
  end

  test "zero disables the gate and unset leaves the default to the worker" do
    refute Keyword.has_key?(run_config(), :mem_lowwater_kb)
    System.put_env("HARNESS_NODE_MEM_LOWWATER_GB", "0")
    assert run_config()[:mem_lowwater_kb] == 0
  end

  test "invalid headroom override fails loudly" do
    System.put_env("HARNESS_NODE_MEM_LOWWATER_GB", "invalid")
    assert_raise ArgumentError, fn -> run_config() end
  end

  defp run_config do
    "../../../config/runtime.exs"
    |> Path.expand(__DIR__)
    |> Config.Reader.read!(env: :dev, target: :host)
    |> Keyword.fetch!(:harness)
    |> Keyword.fetch!(:run)
  end
end
