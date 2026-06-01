defmodule Harness.Benchmark.Eval.Oban.ReverseTest do
  use ExUnit.Case, async: true

  alias Harness.Benchmark.Eval.Oban.Reverse

  test "perform/1 reverses text" do
    job = %Oban.Job{args: %{"text" => "harness"}}
    assert {:ok, "ssenrah"} = Reverse.perform(job)
  end

  test "perform/1 errors without text" do
    assert {:error, :missing_text} = Reverse.perform(%Oban.Job{args: %{}})
  end
end
