defmodule Harness.Audit.Worker do
  @moduledoc """
  Oban worker that runs one post-merge audit pass for a project.

  Enqueued by `Harness.Lander` after every successful push, onto the global
  `:audit` queue (limit 1, so audit agent runs are serialized). Jobs are
  **unique per project while waiting** (`unique` on `project_name`, states
  `available`/`scheduled`): rapid successive lands collapse into one pending
  audit job, whose range computation at perform time covers everything landed
  since the last `audit(...)` commit anyway.

  The worker stays thin: build the request, audit, route. Every outcome except a
  mechanical `{:error, _}` resolves `:ok` — the audit is best-effort by design
  and must never park the queue on a range it can't improve.
  """

  use Oban.Worker, queue: :audit, max_attempts: 2

  alias Harness.Audit
  alias Harness.ProjectRegistry

  require Logger

  # Dedup deliberately covers ONLY waiting jobs — an *executing* audit has
  # already computed its range and won't see commits landed after it started, so
  # a land during execution must insert a fresh job. Passed at insert time (not
  # in `use Oban.Worker`) because Oban's compile-time validation warns on any
  # states list narrower than :incomplete; the narrowing here is the point.
  @unique [keys: [:project_name], period: :infinity, states: [:available, :scheduled]]

  @doc """
  Uniqueness options for audit job inserts — pass as `new(args, unique: unique_opts())`.

  One pending audit job per project: a land while another audit job is still
  waiting dedups into it (that job's range computation covers both lands).
  """
  @spec unique_opts() :: keyword()
  def unique_opts, do: @unique

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(%Oban.Job{args: args}) do
    with {:ok, project_name} <- fetch_arg(args, "project_name"),
         {:ok, base_sha} <- fetch_arg(args, "base_sha"),
         {:ok, project} <- ProjectRegistry.lookup(project_name) do
      %{
        project: project,
        base_sha: base_sha,
        implementer: args["implementer"],
        reviewer: args["reviewer"]
      }
      |> Audit.run()
      |> route(args)
    else
      {:error, reason} -> {:cancel, reason}
    end
  end

  # Best-effort routing: only a mechanical failure earns an Oban retry; every
  # judged-or-degenerate outcome settles :ok so the queue keeps draining.
  @spec route(Audit.outcome(), map()) :: Oban.Worker.result()
  defp route({:audited, sha}, args) do
    Logger.info("harness audit: audited project #{args["project_name"]} at #{sha}")
    :ok
  end

  defp route({:skipped, reason}, args) do
    Logger.info("harness audit: skipped project #{args["project_name"]}: #{inspect(reason)}")
    :ok
  end

  defp route({:error, reason}, _args), do: {:error, reason}
  defp route(_noop_or_dropped, _args), do: :ok

  @spec fetch_arg(map(), String.t()) :: {:ok, String.t()} | {:error, {:missing_arg, String.t()}}
  defp fetch_arg(args, key) do
    case Map.fetch(args, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _other -> {:error, {:missing_arg, key}}
    end
  end
end
