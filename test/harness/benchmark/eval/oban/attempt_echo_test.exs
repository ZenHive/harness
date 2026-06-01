defmodule Harness.Benchmark.Eval.Oban.AttemptEchoTest do
  use ExUnit.Case, async: true

  alias Harness.Benchmark.Eval.Oban.AttemptEcho

  test "perform/1 echoes attempt" do
    job = %Oban.Job{attempt: 2}
    assert {:ok, %{attempt: 2}} = AttemptEcho.perform(job)
  end
end
