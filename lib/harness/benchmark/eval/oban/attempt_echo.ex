defmodule Harness.Benchmark.Eval.Oban.AttemptEcho do
  @moduledoc false
  use Oban.Worker, queue: :bench_eval_attempt

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: {:ok, %{attempt: pos_integer()}}
  def perform(%Oban.Job{attempt: attempt}) when is_integer(attempt) and attempt > 0 do
    {:ok, %{attempt: attempt}}
  end
end
