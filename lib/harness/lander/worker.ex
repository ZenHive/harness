defmodule Harness.Lander.Worker do
  @moduledoc """
  Oban worker that lands one approved run onto its project's target branch.

  Enqueued by `Harness.Run` when a run settles green under a `landing_policy:
  :auto` project, onto the serialized `landing_<name>` queue (limit 1). Resolves
  the project from the registry and delegates to `Harness.Lander.land/1`,
  mapping the structured outcome to Oban's worker contract:

    * `{:landed, _}` → `:ok`
    * `{:post_merge_red, _}` / `{:conflict, _}` / `{:push_rejected, _}` /
      `{:skipped, _}` → `{:cancel, outcome}` — terminal for the happy-path
      lander; Task 101 owns repair/retry of these.
    * `{:error, reason}` → `{:error, reason}` — a transient failure (fetch,
      checkout) Oban retries up to `max_attempts`.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Harness.Lander
  alias Harness.ProjectRegistry

  require Logger

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(%Oban.Job{args: args}) do
    with {:ok, project_name} <- fetch_arg(args, "project_name"),
         {:ok, branch} <- fetch_arg(args, "branch"),
         {:ok, project} <- ProjectRegistry.lookup(project_name) do
      %{
        project: project,
        run_id: args["run_id"],
        task_id: args["task_id"],
        agent: args["agent"],
        branch: branch
      }
      |> Lander.land()
      |> to_oban_result(args)
    else
      {:error, reason} -> {:cancel, reason}
    end
  end

  @spec to_oban_result(Lander.outcome(), map()) :: Oban.Worker.result()
  defp to_oban_result({:landed, sha}, args) do
    Logger.info("harness lander: landed task #{args["task_id"]} (run #{args["run_id"]}) at #{sha}")
    :ok
  end

  defp to_oban_result({:error, reason}, _args), do: {:error, reason}

  defp to_oban_result(outcome, args) do
    Logger.warning("harness lander: task #{args["task_id"]} did not land: #{inspect(outcome)}")
    {:cancel, outcome}
  end

  @spec fetch_arg(map(), String.t()) :: {:ok, String.t()} | {:error, {:missing_arg, String.t()}}
  defp fetch_arg(args, key) do
    case Map.fetch(args, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _other -> {:error, {:missing_arg, key}}
    end
  end
end
