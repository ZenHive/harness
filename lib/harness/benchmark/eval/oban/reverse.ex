defmodule Harness.Benchmark.Eval.Oban.Reverse do
  @moduledoc false
  use Oban.Worker, queue: :bench_eval_reverse

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:ok, String.t()} | {:error, term()}
  def perform(%Oban.Job{args: %{"text" => text}}) when is_binary(text) do
    {:ok, String.reverse(text)}
  end

  def perform(%Oban.Job{}), do: {:error, :missing_text}
end
