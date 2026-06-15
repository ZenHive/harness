defmodule Harness.Lander.Resilience do
  @moduledoc """
  Routes a `Harness.Lander.land/1` outcome to its repair action — the merge-train
  resilience layer (Task 101) that replaces the happy-path lander's dead-end.

  ## Pure decision, then effect

  `plan/2` is a pure, exhaustive function over the outcome union: given the
  outcome and the current `land_attempt`, it returns an *action* — no git, no
  Oban, no rmap. `route/2` reads `land_attempt` from the worker args, calls
  `plan/2`, and applies the action's effects, returning an `Oban.Worker`
  result. Repair handoffs return `{:cancel, reason}` so Oban never records an
  unlanded branch as a completed landing job. The split keeps the cap/routing
  logic unit-testable without spawning runs or touching a repo.

  ## Routing table

    * `{:landed, sha}` → `:ok` (terminal — the worker logs the SHA).
    * `{:skipped, reason}` → `:ok` (nothing to act on, e.g. a `{:github, _}`
      source the lander can't push to).
    * `{:error, reason}` → `{:error, reason}` (a transient fetch/checkout
      failure — Oban backs off and retries the *same* landing job).
    * autonomous `{:conflict, _}` → **retain the reviewer-approved branch**,
      mark the task `blocked`, and witness the conflict — never a fresh
      implementer run. A `{:conflict, _}` only reaches here *after* the lander's
      in-worktree merge-resolver agent (Task 189) already tried and failed to
      reconcile the markers, so the committed, reviewed branch is paid for and
      must be recovered, not redone. Recovery is operator-driven `dispatch-reland`
      (a zero-token re-land of the retained branch once the conflicting change has
      settled). This is attempt-independent: re-running the implementer would only
      reproduce the same conflict at the cost of fresh tokens.
    * non-command `{:reflex_halt, _}` → **fresh re-dispatch** of the task against
      the current target HEAD (a new run branches off the integrated tip by
      construction) while under the attempt cap; at the cap, the task is marked
      `blocked`. (Distinct trigger from a conflict — the reflex floor halted the
      land, there is no reviewed branch to re-land.)
    * operator-invoked manual reland `{:conflict, _}` → retain the branch and
      witness the conflict without changing roadmap status or starting a fresh
      implementer run (the operator already decided to re-land). The lander still
      invokes the merge-resolver on a fresh rebase conflict before this route
      fires; `:manual_reland_conflict` means that attempt also failed — recovery
      is operator three-way merge + `dispatch-reland`, not a second resolver pass
      from resilience.
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
  alias Harness.Dashboard.OpsFeed
  alias Harness.Dashboard.OpsFeed.Op
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
          | {:conflict_retain, String.t()}
          | {:manual_reland_conflict, String.t()}
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
      {:conflict_retain, "CONFLICT"}

      iex> Harness.Lander.Resilience.plan({:conflict, "CONFLICT"}, 2)
      {:conflict_retain, "CONFLICT"}
  """
  @spec plan(Lander.outcome(), pos_integer()) :: action()
  def plan({:landed, _sha} = landed, _attempt), do: {:ok, landed}
  def plan({:skipped, _reason} = skipped, _attempt), do: {:ok, skipped}
  def plan({:error, reason}, _attempt), do: {:retry, reason}

  # A resolver-failed conflict never re-dispatches: the reviewed branch is
  # retained, the task is blocked, and recovery is operator-driven dispatch-reland.
  def plan({:conflict, output}, _attempt), do: {:conflict_retain, output}

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
  def route({:conflict, output}, %{"manual_reland" => true} = args) when is_binary(output) do
    apply_action({:manual_reland_conflict, output}, args)
  end

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
  defp apply_action({:conflict_retain, output}, args), do: conflict_retain(args, output)
  defp apply_action({:manual_reland_conflict, output}, args), do: manual_reland_conflict(args, output)
  defp apply_action({:block, tag}, args), do: block(args, tag)

  # A *fresh* run (not a session-resume): re-ingest the task and start a new run
  # off the current target HEAD, carrying the bumped attempt so its own landing
  # job inherits the cap. A start failure surfaces as {:error, _} so Oban retries
  # this landing job rather than silently dropping the repair.
  @spec redispatch(map(), pos_integer(), reason_tag()) :: Oban.Worker.result()
  defp redispatch(args, attempt, tag) do
    with {:ok, project} <- ProjectRegistry.lookup(args["project_name"]),
         {:ok, {module, render_agent}} <- Registry.resolve(args["agent"]),
         {:ok, item} <- ingest_roadmap({:id, args["task_id"]}, project: project, agent: render_agent),
         {:ok, run_id, _pid} <-
           start_run(item, project, module, land_attempt: attempt, subscriber: nil) do
      Logger.info(
        "harness lander: re-dispatched task #{args["task_id"]} after #{tag} (attempt #{attempt}, run #{run_id})"
      )

      {:cancel, {:redispatched, run_id}}
    else
      {:error, reason} -> {:error, {:redispatch_failed, reason}}
    end
  end

  @spec ingest_roadmap(Roadmap.selector(), keyword()) :: {:ok, Roadmap.Item.t()} | {:error, term()}
  defp ingest_roadmap(selector, opts) do
    case Application.get_env(:harness, :roadmap_ingest) do
      fun when is_function(fun, 2) -> fun.(selector, opts)
      _other -> Roadmap.ingest(selector, opts)
    end
  end

  @spec start_run(Roadmap.Item.t(), Harness.Project.t(), module(), keyword()) ::
          {:ok, String.t(), pid()} | {:error, term()}
  defp start_run(%Roadmap.Item{} = item, project, adapter, opts) do
    case Application.get_env(:harness, :run_starter) do
      fun when is_function(fun, 4) -> fun.(item, project, adapter, opts)
      _other -> RunSupervisor.start_run(item, project, adapter, opts)
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
           |> LanderWorker.new_for_project(project)
           |> HarnessOban.insert() do
      Logger.info("harness lander: re-landing task #{args["task_id"]} (attempt #{attempt})")
      {:cancel, {:reland_enqueued, attempt}}
    else
      {:error, reason} -> {:error, {:reland_failed, reason}}
    end
  end

  # Autonomous conflict: the merge-resolver agent already tried and failed, so the
  # reviewer-approved branch is retained, the task is marked blocked, and the conflict
  # is witnessed — never a fresh implementer run. Recovery is operator-driven
  # dispatch-reland. A mark-blocked failure is logged (mirrors block/2) but the job
  # still cancels so the train never loops on a conflict it has refused.
  @spec conflict_retain(map(), String.t()) :: Oban.Worker.result()
  defp conflict_retain(args, output) do
    reason = conflict_repair_reason(args, "land conflict retained for repair", output)

    case mark_blocked(args["project_name"], args["task_id"], reason) do
      {:ok, _output} ->
        Logger.warning(
          "harness lander: retained conflicted branch #{args["branch"]} for task #{args["task_id"]}: #{reason}"
        )

      {:error, mark_reason} ->
        Logger.error(
          "harness lander: failed to mark task #{args["task_id"]} blocked (#{inspect(mark_reason)}); reason was: #{reason}"
        )
    end

    Notification.notify(event(:conflict, output, args))
    OpsFeed.broadcast(Op.blocked(args, reason))
    {:cancel, {:conflict_retained, reason}}
  end

  @spec manual_reland_conflict(map(), String.t()) :: Oban.Worker.result()
  defp manual_reland_conflict(args, output) do
    reason = conflict_repair_reason(args, "manual reland conflict retained for repair", output)

    Logger.warning(
      "harness lander: manual reland retained conflicted branch #{args["branch"]} for task #{args["task_id"]}: #{reason}"
    )

    Notification.notify(event(:conflict, reason, args))
    {:cancel, {:manual_reland_conflict, reason}}
  end

  @spec conflict_repair_reason(map(), String.t(), String.t()) :: String.t()
  defp conflict_repair_reason(args, prefix, output) do
    "#{prefix} (task #{args["task_id"]}, run #{args["run_id"]}, branch #{args["branch"]}); " <>
      "resolver already attempted and the branch still conflicted.#{resolver_witness(output)} Repair: rebase the retained branch onto " <>
      "the target branch, resolve all conflict markers while keeping both reviewed intents, commit the " <>
      "resolved branch, move #{args["branch"]} to that commit if you used a scratch branch, then run " <>
      "dispatch-reland #{args["run_id"]}."
  end

  @spec resolver_witness(String.t()) :: String.t()
  defp resolver_witness(output) do
    case Regex.run(~r/Harness resolver witness: ([^\n]+)/, output) do
      [_match, witness] -> " resolver witness: #{witness}."
      nil -> ""
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
    OpsFeed.broadcast(Op.blocked(args, reason))
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
