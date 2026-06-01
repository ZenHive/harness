defmodule Harness.Benchmark.Eval.Elixir.PipelineTest do
  use ExUnit.Case, async: true

  alias Harness.Benchmark.Eval.Elixir.Pipeline

  test "parse_int/1 accepts positive integers" do
    assert {:ok, 42} = Pipeline.parse_int("  42 ")
  end

  test "parse_int/1 rejects negatives and invalid input" do
    assert {:error, :negative} = Pipeline.parse_int("-1")
    assert {:error, :invalid} = Pipeline.parse_int("abc")
  end
end
