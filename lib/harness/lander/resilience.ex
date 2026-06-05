defmodule Harness.Lander.Resilience do
  @moduledoc """
  Routes a `Harness.Lander.land/1` outcome to its repair action — the merge-train
  resilience layer (Task 101) that replaces the happy-path lander's dead-end.

  ## Pure decision, then effect

  `plan/2` is a pure, exhaustive function over the outcome union: given the
  outcome and the current `land_attempt`, it returns an *action* — no git, no
  Oban, no rmap. `route/2` reads `land_attempt` from the worker args, calls
  `plan/2`, and applies the action's effects, returning an `Oban.Worker`
  result. The split keeps the cap/routing logic unit-testable without spawning
  runs or touching a repo.

  ## Routing table

    * `{:landed, sha}` → `:ok` (terminal — the worker logs the SHA).
    * `{:skipped, reason}` → `:ok` (nothing to act on, e.g. a `{:github, _}`
      source the lander can't push to).
    * `{:error, reason}` → `{:error, reason}` (a transient fetch/checkout
      failure — Oban backs off and retries the *same* landing job).
    * `{:conflict, _}` / non-command `{:reflex_halt, _}` → **fresh re-dispatch**
      of the task against the current target HEAD (a new run branches off the
      integrated tip by construction) while under the attempt cap; at the cap,
      the task is marked `blocked`. A `{:conflict, _}` only reaches here *after*
      the lander's in-worktree merge-resolver agent (Task 189) already tried and
      failed to reconcile the markers — re-dispatch is the documented fallback.
    * blocked-command `{:reflex_halt, {:blocked_command, _}}` → `blocked`
      immediately.
    * `{:push_rejected, _}` → **re-land** the retained branch (re-fetch / rebase
      / push) while under the cap; at the cap, `blocked`.

  ## The attempt cap

  `@max_land_attempts` bounds total land attempts per task: the original run's
  land (`land_attempt: 1`) plus **one** fresh re-dispatch or re-land
  (`land_attempt: 2`). A second failure (`attempt == @max_land_attempts`) routes
  to the `blocked` sink with a structured reason, terminating the train for that
  task without an Oban retry.
  """

  alias Harness.AgentAdapter.Registry
  alias Harness.Lander
  alias Harness.Lander.Worker, as: LanderWorker
  alias Harness.Notification
  alias Harness.Notification.Event
  alias Harness.Oban, as: HarnessOban
  alias Harness.ProjectRegistry
  alias Harness.Roadmap
  alias Harness.Run.Supervisor, as: RunSupervisor

  require Logger

  # Total land attempts per task: the initial land + one fresh re-dispatch/re-land.
  @max_land_attempts 2

  @typedoc "Which non-landed outcome exhausted the cap — names the blocked reason."
  @type reason_tag :: :conflict | :push_rejected | :reflex_halt

  @typedoc "A pure routing decision produced by `plan/2`."
  @type action ::
          {:ok, Lander.outcome()}
          | {:retry, term()}
          | {:redispatch, pos_integer(), reason_tag()}
          | {:reland, pos_integer()}
          | {:block, reason_tag()}

  @doc """
  Pure routing decision for a land `outcome` at the given `attempt`.

  Exhaustive over `t:Harness.Lander.outcome/0`. Recoverable non-landed outcomes
  route to a re-dispatch/re-land while `attempt < #{@max_land_attempts}`, and to
  `{:block, tag}` at the cap.

  ## Examples

      iex> Harness.Lander.Resilience.plan({:landed, "abc123"}, 1)
      {:ok, {:landed, "abc123"}}

      iex> Harness.Lander.Resilience.plan({:conflict, "CONFLICT"}, 1)
      {:redispatch, 2, :conflict}

      iex> Harness.Lander.Resilience.plan({:conflict, "CONFLICT"}, 2)
      {:block, :conflict}
  """
  @spec plan(Lander.outcome(), pos_integer()) :: action()
  def plan({:landed, _sha} = landed, _attempt), do: {:ok, landed}
  def plan({:skipped, _reason} = skipped, _attempt), do: {:ok, skipped}
  def plan({:error, reason}, _attempt), do: {:retry, reason}

  def plan({:conflict, _output}, attempt), do: cap(attempt, {:redispatch, attempt + 1, :conflict}, :conflict)

  def plan({:push_rejected, _output}, attempt), do: cap(attempt, {:reland, attempt + 1}, :push_rejected)

  def plan({:reflex_halt, {:blocked_command, _command}}, _attempt), do: {:block, :reflex_halt}

  def plan({:reflex_halt, _reason}, attempt), do: cap(attempt, {:redispatch, attempt + 1, :reflex_halt}, :reflex_halt)

  # Under the cap → the recoverable action; at the cap → block.
  @spec cap(pos_integer(), action(), reason_tag()) :: action()
  defp cap(attempt, under_cap, tag) do
    if attempt < @max_land_attempts, do: under_cap, else: {:block, tag}
  end

  @doc """
  Applies the routing decision for `outcome` (read `land_attempt` from `args`)
  and returns the `Oban.Worker` result for `Harness.Lander.Worker`.
  """
  @spec route(Lander.outcome(), map()) :: Oban.Worker.result()
  def route(outcome, args) do
    attempt = Map.get(args, "land_attempt", 1)

    outcome
    |> plan(attempt)
    |> apply_action(args)
  end

  @spec apply_action(action(), map()) :: Oban.Worker.result()
  defp apply_action({:ok, {:landed, sha}}, args) do
    Logger.info("harness lander: landed task #{args["task_id"]} (run #{args["run_id"]}) at #{sha}")
    Notification.notify(event(:landed, sha, args))
    :ok
  end

  defp apply_action({:ok, {:skipped, reason}}, args) do
    Logger.info("harness lander: skipped task #{args["task_id"]}: #{inspect(reason)}")
    :ok
  end

  defp apply_action({:retry, reason}, _args), do: {:error, reason}
  defp apply_action({:redispatch, attempt, tag}, args), do: redispatch(args, attempt, tag)
  defp apply_action({:reland, attempt}, args), do: reland(args, attempt)
  defp apply_action({:block, tag}, args), do: block(args, tag)

  # A *fresh* run (not a session-resume): re-ingest the task and start a new run
  # off the current target HEAD, carrying the bumped attempt so its own landing
  # job inherits the cap. A start failure surfaces as {:error, _} so Oban retries
  # this landing job rather than silently dropping the repair.
  @spec redispatch(map(), pos_integer(), reason_tag()) :: Oban.Worker.result()
  defp redispatch(args, attempt, tag) do
    with {:ok, project} <- ProjectRegistry.lookup(args["project_name"]),
         {:ok, {module, render_agent}} <- Registry.resolve(args["agent"]),
         {:ok, item} <- Roadmap.ingest({:id, args["task_id"]}, project: project, agent: render_agent),
         {:ok, run_id, _pid} <-
           RunSupervisor.start_run(item, project, module, land_attempt: attempt, subscriber: nil) do
      Logger.info(
        "harness lander: re-dispatched task #{args["task_id"]} after #{tag} (attempt #{attempt}, run #{run_id})"
      )

      :ok
    else
      {:error, reason} -> {:error, {:redispatch_failed, reason}}
    end
  end

  # Re-insert a landing job for the retained branch on the serialized landing
  # queue, carrying the bumped attempt — the branch re-lands (re-fetch / rebase /
  # push) after whatever advanced the target has settled.
  @spec reland(map(), pos_integer()) :: Oban.Worker.result()
  defp reland(args, attempt) do
    with {:ok, project} <- ProjectRegistry.lookup(args["project_name"]),
         {:ok, _job} <-
           args
           |> Map.put("land_attempt", attempt)
           |> LanderWorker.new(queue: HarnessOban.landing_queue_name(project))
           |> HarnessOban.insert() do
      Logger.info("harness lander: re-landing task #{args["task_id"]} (attempt #{attempt})")
      :ok
    else
      {:error, reason} -> {:error, {:reland_failed, reason}}
    end
  end

  # Terminal: cap exhausted. Mark the task blocked with a structured reason; a
  # writeback failure is logged but the job still cancels (no Oban retry) — the
  # train must not loop on a task it has refused.
  @spec block(map(), reason_tag()) :: Oban.Worker.result()
  defp block(args, tag) do
    reason =
      "land-cap exhausted after #{tag} x#{@max_land_attempts} (task #{args["task_id"]}, last run #{args["run_id"]})"

    case mark_blocked(args["project_name"], args["task_id"], reason) do
      {:ok, _output} ->
        Logger.warning("harness lander: blocked task #{args["task_id"]}: #{reason}")

      {:error, mark_reason} ->
        Logger.error(
          "harness lander: failed to mark task #{args["task_id"]} blocked (#{inspect(mark_reason)}); reason was: #{reason}"
        )
    end

    Notification.notify(event(:blocked, reason, args))
    {:cancel, {:blocked, reason}}
  end

  # Builds a witness Event from the worker args + the type-specific outcome
  # payload (landed SHA / blocked reason).
  @spec event(Event.type(), Event.outcome(), map()) :: Event.t()
  defp event(type, outcome, args) do
    %Event{
      type: type,
      task_id: args["task_id"],
      run_id: args["run_id"],
      project: args["project_name"],
      branch: args["branch"],
      land_attempt: Map.get(args, "land_attempt", 1),
      outcome: outcome
    }
  end

  @spec mark_blocked(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp mark_blocked(project_name, task_id, reason) do
    with {:ok, project} <- ProjectRegistry.lookup(project_name) do
      Roadmap.mark_blocked(task_id, project: project, reason: reason)
    end
  end
end
