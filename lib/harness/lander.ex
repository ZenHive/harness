defmodule Harness.Lander do
  @moduledoc """
  Autonomous merge-train: lands an approved run onto a project's target branch.

  When a run settles `:done` (the reviewer AI approved it) under a project with
  `landing_policy: :auto`, `Harness.Run` enqueues a landing job on the project's
  serialized `landing_<name>` Oban queue (limit 1, so one approved run lands at
  a time per project). `Harness.Lander.Worker` resolves the project and calls
  `land/1`, which:

    1. `git fetch origin`,
    2. checks out the settled run's `harness/<run-id>` branch into a fresh
       **detached** worktree and, if `origin/<target>` has moved past it,
       rebases onto it,
    3. fast-forward-pushes the tip to `origin/<target_branch>` (never `--force`;
       then fast-forwards the operator's local target ref when Git says it is
       safe),
    4. writes the outcome back to rmap (`done` + `verified` + `shipped_in`),
    5. enqueues a post-merge audit job (`Harness.Audit.Worker`) for the landed
       range — best-effort, never blocks the land.

  There is **no re-verification step**: the reviewer AI already gated the work
  (it ran the project's checks itself); the lander is pure git mechanics. The
  post-merge audit agent is the safety net for integration drift.

  ## Land mechanism: remote fast-forward push

  Landing is a ff-only `git push origin <tip>:refs/heads/<target>`. The push
  target is the *remote* branch. After that succeeds, harness attempts a local
  ff-only sync: an unchecked-out local target ref is updated by fetch, while a
  clean checked-out target is advanced by `git merge --ff-only origin/<target>`.
  Dirty or non-ff local state is left alone and surfaced as a notification.
  `shipped_in` is the pushed SHA.

  ## Failure routing (Task 101 seam)

  This is the happy-path lander. A non-`:landed` outcome — `{:conflict, output}`
  (rebase hit a conflict), `{:push_rejected, output}` (the target advanced under
  us) — **retains the branch, does not push or write back, and returns the
  structured tuple.** Conflict redispatch and a blocked sink are
  `Harness.Lander.Resilience`'s job; they plug into these tuples.
  `{:skipped, reason}` covers a project the lander can't act on yet (e.g. a
  `{:github, _}` source).
  """

  alias Harness.AgentRegistry
  alias Harness.Audit.Worker, as: AuditWorker
  alias Harness.Dashboard.OpsFeed
  alias Harness.Dashboard.OpsFeed.Op
  alias Harness.Git
  alias Harness.Git.TargetSync
  alias Harness.Lander.Resolver
  alias Harness.Lander.Worker, as: LanderWorker
  alias Harness.Notification
  alias Harness.Notification.Event
  alias Harness.Oban, as: HarnessOban
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.Roadmap
  alias Harness.Run.LogRecord
  alias Harness.Worktree

  require Logger

  @typedoc "The settled run a landing job carries (built by the worker from Oban args)."
  @type request :: %{
          :project => Project.t(),
          :run_id => String.t(),
          :task_id => String.t(),
          :branch => String.t(),
          optional(:agent) => atom() | String.t() | nil,
          optional(:reviewer) => atom() | String.t() | nil
        }

  @typedoc "The structured result of a land attempt."
  @type outcome ::
          {:landed, String.t()}
          | {:conflict, String.t()}
          | {:push_rejected, String.t()}
          | {:reflex_halt, term()}
          | {:skipped, term()}
          | {:error, term()}

  @doc """
  Lands `request`'s approved branch onto the project's target branch.

  See the module doc for the procedure and the outcome vocabulary. Idempotent:
  re-running after a successful land re-pushes the same SHA (a git no-op) and
  re-marks the task `done` (an rmap no-op), so an Oban retry is safe.
  """
  @spec land(request()) :: outcome()
  def land(%{project: %Project{} = project, branch: branch} = request) when is_binary(branch) do
    OpsFeed.broadcast(Op.land_started(request))

    outcome =
      with {:ok, repo} <- Project.local_repo_path(project),
           {:ok, target} <- target_branch(project),
           :ok <- fetch_origin(repo),
           {:ok, base_sha} <- remote_target_sha(repo, target),
           {:ok, worktree} <- checkout(repo, branch) do
        land_in_worktree(worktree, repo, target, base_sha, project, request)
      end

    OpsFeed.broadcast(Op.land_settled(request, outcome))
    outcome
  end

  @doc """
  Manually enqueue a landing job for a settled run by `run_id` — the operator
  "Re-land" path for a run whose automatic land-train hit its cap and blocked
  the task.

  Reconstructs the landing args from the persisted run record (`run_id`,
  `task_id`, `project_name`, `agent`, reviewer family) and inserts a fresh
  `Harness.Lander.Worker` job at `land_attempt: 1` on the project's serialized
  `landing_<name>` queue — the same job shape the automatic train enqueues, so
  it re-fetches, rebases onto the current target, and pushes.

  Mechanical by design: it does **not** judge whether a re-land is warranted —
  the caller (operator clicking the dashboard button, or an orchestrator)
  decides; harness only re-enqueues.
  """
  @spec enqueue(String.t()) ::
          {:ok, %{run_id: String.t(), task_id: String.t()}} | {:error, :not_found | term()}
  def enqueue(run_id) when is_binary(run_id) do
    with {:ok, record} <- load_record(run_id),
         {:ok, project} <- ProjectRegistry.lookup(record.project_name),
         {:ok, _job} <- insert_landing(record, project) do
      {:ok, %{run_id: run_id, task_id: record.task_id}}
    end
  end

  @spec load_record(String.t()) :: {:ok, LogRecord.t()} | {:error, :not_found | term()}
  defp load_record(run_id) do
    case ResultStore.list_run_records(run_id: run_id) do
      {:ok, [%LogRecord{} = record | _]} -> {:ok, record}
      {:ok, []} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec insert_landing(LogRecord.t(), Project.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  defp insert_landing(%LogRecord{} = record, %Project{} = project) do
    record
    |> landing_args(project)
    |> LanderWorker.new_for_project(project)
    |> HarnessOban.insert()
  end

  # The Oban-arg map a manual re-land enqueues, reconstructed from the persisted
  # run record. Pure (@doc false) so the reconstruction is testable without an
  # Oban instance or a database — the branch is derived from the run id, the
  # attempt resets to 1 (a fresh operator-initiated land cycle).
  @doc false
  @spec landing_args(LogRecord.t(), Project.t()) :: %{optional(String.t()) => term()}
  def landing_args(%LogRecord{} = record, %Project{} = project) do
    %{
      "project_name" => project.name,
      "run_id" => record.run_id,
      "task_id" => record.task_id,
      "agent" => to_string(record.agent),
      "reviewer" => reviewer_name(record.reviewer_adapter),
      "branch" => "harness/" <> record.run_id,
      "land_attempt" => 1
    }
  end

  # The reviewer's agent-family name (∉ {implementer, auditor}) threaded onto the
  # landing job so a post-merge audit can pick a third family. Best-effort: an
  # unrecognized module just drops to nil (audit falls back).
  @spec reviewer_name(module() | nil) :: String.t() | nil
  defp reviewer_name(nil), do: nil

  defp reviewer_name(module) do
    case AgentRegistry.agent_for_module(module) do
      {:ok, agent} -> to_string(agent)
      {:error, _reason} -> nil
    end
  end

  @spec land_in_worktree(Worktree.t(), String.t(), String.t(), String.t(), Project.t(), request()) :: outcome()
  defp land_in_worktree(%Worktree{} = worktree, repo, target, base_sha, project, request) do
    result =
      with {:ok, tip} <- integrate(worktree, target, base_sha, request),
           {:ok, pushed} <- push(repo, tip, target) do
        sync_local_target(repo, target, project, request)
        writeback(project, request, pushed)
        enqueue_audit(project, request, base_sha)
        {:landed, pushed}
      else
        {:conflict, _output} = conflict -> conflict
        {:push_rejected, _output} = rejected -> rejected
        {:error, reason} -> {:error, reason}
      end

    cleanup(worktree)
    result
  end

  # origin/<target> already an ancestor of the branch tip -> ff-able as-is.
  # Otherwise the target moved, so rebase the branch onto it; a rebase that
  # hits a conflict is handed to the merge-resolver agent (Task 189) before any
  # fallback to the resilience layer.
  @spec integrate(Worktree.t(), String.t(), String.t(), request()) ::
          {:ok, String.t()} | {:conflict, String.t()} | {:error, term()}
  defp integrate(%Worktree{} = worktree, target, base_sha, request) do
    origin_ref = "origin/" <> target

    case Git.run(["merge-base", "--is-ancestor", origin_ref, "HEAD"], worktree.path) do
      {:ok, _output} -> head_sha(worktree.path)
      {:error, {:git_failed, _args, 1, _output}} -> rebase_onto(worktree, origin_ref, base_sha, request)
      {:error, reason} -> {:error, {:ancestry_check_failed, reason}}
    end
  end

  # A clean rebase ff-lands as before. A conflict is NOT aborted up-front: the
  # worktree is left mid-rebase (markers in place) and a cross-family resolver
  # agent is given a chance to reconcile. Only if resolution fails do we abort
  # and surface `{:conflict, _}` for the resilience layer's re-dispatch.
  @spec rebase_onto(Worktree.t(), String.t(), String.t(), request()) ::
          {:ok, String.t()} | {:conflict, String.t()} | {:error, term()}
  defp rebase_onto(%Worktree{path: path} = worktree, origin_ref, base_sha, request) do
    case Git.run(["rebase", origin_ref], path) do
      {:ok, _output} -> head_sha(path)
      {:error, {:git_failed, _args, _status, output}} -> resolve_or_abort(worktree, base_sha, request, output)
    end
  end

  # The agent edits the worktree (Resolver), then harness mechanically stages,
  # asserts zero leftover conflict markers, and continues the rebase. Any
  # failure — resolver unavailable, the agent declined, markers still present,
  # or `rebase --continue` rejecting — aborts the rebase and falls back to the
  # existing `{:conflict, _}` -> re-dispatch path. A still-conflicted tree is
  # never landed. No re-verification: the reviewer already approved both sides.
  @spec resolve_or_abort(Worktree.t(), String.t(), request(), String.t()) ::
          {:ok, String.t()} | {:conflict, String.t()}
  defp resolve_or_abort(%Worktree{path: path} = worktree, base_sha, request, conflict_output) do
    OpsFeed.broadcast(Op.land_stage(request, :resolving))

    with :ok <- run_resolver(worktree, base_sha, request),
         :ok <- stage_all(path),
         :ok <- assert_resolved(path),
         {:ok, tip} <- continue_rebase(path) do
      Logger.info("harness lander: merge-resolver reconciled rebase conflict for task #{request.task_id}")
      {:ok, tip}
    else
      {:error, reason} ->
        _ = Git.run(["rebase", "--abort"], path)

        Logger.info(
          "harness lander: merge-resolver fell back to re-dispatch for task #{request.task_id} (#{inspect(reason)})"
        )

        {:conflict, conflict_output}
    end
  end

  @spec run_resolver(Worktree.t(), String.t(), request()) :: :ok | {:error, term()}
  defp run_resolver(%Worktree{} = worktree, base_sha, request) do
    resolver_fun().(worktree,
      implementer: request[:agent],
      reviewer: request[:reviewer],
      task_id: request.task_id,
      base_sha: base_sha
    )
  end

  # Injectable (mirrors `:oban_insert`) so the suite exercises the git finalize
  # without spawning a real agent. Default is the live cross-family resolver.
  @spec resolver_fun() :: (Worktree.t(), keyword() -> :ok | {:error, term()})
  defp resolver_fun, do: Application.get_env(:harness, :lander_resolver, &Resolver.resolve/2)

  @spec stage_all(String.t()) :: :ok | {:error, term()}
  defp stage_all(path) do
    case Git.run(["add", "-A"], path) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:stage_failed, reason}}
    end
  end

  # Authoritative leftover-marker gate: `git diff --cached --check` flags any
  # staged line that introduces a conflict marker. Whitespace-only `--check`
  # noise (also non-zero) never blocks a land — only "conflict marker" does.
  @spec assert_resolved(String.t()) :: :ok | {:error, term()}
  defp assert_resolved(path) do
    case Git.run(["diff", "--cached", "--check"], path) do
      {:ok, _output} ->
        :ok

      {:error, {:git_failed, _args, _status, output}} ->
        if String.contains?(output, "conflict marker"),
          do: {:error, {:unresolved_markers, output}},
          else: :ok
    end
  end

  # `-c core.editor=true` skips the editor for the rebase's resolution commit.
  @spec continue_rebase(String.t()) :: {:ok, String.t()} | {:error, term()}
  defp continue_rebase(path) do
    case Git.run(["-c", "core.editor=true", "rebase", "--continue"], path) do
      {:ok, _output} -> head_sha(path)
      {:error, {:git_failed, _args, _status, output}} -> {:error, {:rebase_continue_failed, output}}
    end
  end

  @spec push(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:push_rejected, String.t()} | {:error, term()}
  defp push(repo, tip, target) do
    case Git.run(["push", "origin", tip <> ":refs/heads/" <> target], repo) do
      {:ok, _output} ->
        {:ok, tip}

      {:error, {:git_failed, _args, status, output}} ->
        if Git.non_fast_forward?(repo, tip, target, status, output),
          do: {:push_rejected, output},
          else: {:error, {:push_failed, output}}
    end
  end

  # After the code ff-push, fast-forward the operator's local target too (shared
  # ff-only sync, never forcing a dirty/diverged checkout) so it doesn't drift
  # behind origin. A skip is surfaced as a witness event.
  @spec sync_local_target(String.t(), String.t(), Project.t(), request()) :: :ok
  defp sync_local_target(repo, target, project, request) do
    case TargetSync.ff_local(repo, target) do
      :synced -> :ok
      {:skipped, reason} -> notify_local_sync_skipped(project, request, reason)
    end
  end

  @spec notify_local_sync_skipped(Project.t(), request(), String.t()) :: :ok
  defp notify_local_sync_skipped(project, request, reason) do
    Logger.warning("harness lander: #{reason}")

    Notification.notify(%Event{
      type: :local_sync_skipped,
      task_id: request.task_id,
      run_id: request.run_id,
      project: project.name,
      branch: request.branch,
      outcome: reason
    })
  end

  # The push succeeded, so the code IS landed; a writeback failure (e.g. rmap's
  # --shipped-in flag not yet present) is logged but never un-lands the merge.
  @spec writeback(Project.t(), request(), String.t()) :: :ok
  defp writeback(%Project{} = project, request, sha) do
    case Roadmap.mark_landed(request.task_id,
           project: project,
           sha: sha,
           delivered_by: delivered_by(request[:agent]),
           implemented: implemented_text(request, sha)
         ) do
      {:ok, _output} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "harness lander: rmap writeback failed for task #{request.task_id} (landed #{sha}): #{inspect(reason)}"
        )

        :ok
    end
  end

  # The post-merge audit trigger: one audit job per land, deduped per project by
  # Oban uniqueness while a job is still waiting. `base_sha` (origin/<target>
  # before this push) is the audit's range fallback when the branch has no prior
  # `audit(...)` commit. Best-effort: an enqueue failure — including a raise when
  # no Oban instance is running — is logged, never un-lands the merge.
  @spec enqueue_audit(Project.t(), request(), String.t()) :: :ok
  defp enqueue_audit(%Project{} = project, request, base_sha) do
    %{
      "project_name" => project.name,
      "base_sha" => base_sha,
      "implementer" => agent_name(request[:agent]),
      "reviewer" => agent_name(request[:reviewer])
    }
    |> AuditWorker.new(unique: AuditWorker.unique_opts())
    |> HarnessOban.insert()
    |> case do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        log_audit_enqueue_failure(project, reason)
    end
  rescue
    error -> log_audit_enqueue_failure(project, error)
  end

  @spec log_audit_enqueue_failure(Project.t(), term()) :: :ok
  defp log_audit_enqueue_failure(%Project{} = project, reason) do
    Logger.warning("harness lander: failed to enqueue audit for project #{project.name}: #{inspect(reason)}")

    :ok
  end

  @spec agent_name(atom() | String.t() | nil) :: String.t() | nil
  defp agent_name(nil), do: nil
  defp agent_name(agent) when is_binary(agent), do: agent
  defp agent_name(agent) when is_atom(agent), do: Atom.to_string(agent)

  @spec delivered_by(atom() | String.t() | nil) :: String.t() | nil
  defp delivered_by(agent), do: agent_name(agent)

  @spec implemented_text(request(), String.t()) :: String.t()
  defp implemented_text(request, sha) do
    by = if agent = request[:agent], do: "by #{agent} ", else: ""
    "Landed #{by}via merge-train; reviewer-approved (run #{request.run_id}, #{sha})."
  end

  @spec cleanup(Worktree.t()) :: :ok
  defp cleanup(%Worktree{} = worktree) do
    case Worktree.remove(worktree) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("harness lander: failed to remove landing worktree #{worktree.path}: #{inspect(reason)}")

        :ok
    end
  end

  @spec target_branch(Project.t()) :: {:ok, String.t()} | {:error, :no_target_branch}
  defp target_branch(%Project{target_branch: tb}) when is_binary(tb) and tb != "", do: {:ok, tb}
  defp target_branch(%Project{}), do: {:error, :no_target_branch}

  @spec fetch_origin(String.t()) :: :ok | {:error, term()}
  defp fetch_origin(repo) do
    case Git.run(["fetch", "origin"], repo) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:fetch_failed, reason}}
    end
  end

  # The target tip *before* this land — captured post-fetch so the audit job
  # knows where the just-landed range starts even when no prior audit(...)
  # commit exists.
  @spec remote_target_sha(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp remote_target_sha(repo, target) do
    case Git.run(["rev-parse", "origin/" <> target], repo) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, reason} -> {:error, {:rev_parse_failed, reason}}
    end
  end

  @spec checkout(String.t(), String.t()) :: {:ok, Worktree.t()} | {:error, term()}
  defp checkout(repo, branch) do
    case Worktree.checkout_existing(repo, branch) do
      {:ok, worktree} -> {:ok, worktree}
      {:error, reason} -> {:error, {:checkout_failed, reason}}
    end
  end

  @spec head_sha(String.t()) :: {:ok, String.t()} | {:error, term()}
  defp head_sha(path) do
    case Git.run(["rev-parse", "HEAD"], path) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, reason} -> {:error, {:rev_parse_failed, reason}}
    end
  end
end
