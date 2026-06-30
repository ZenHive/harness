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
       range — best-effort, never blocks the land,
    6. prunes the settled run's retained branch and implementer worktree.

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
  alias Harness.Roadmap.TaskIdRewriter
  alias Harness.Run.LogRecord
  alias Harness.Worktree

  require Logger

  @default_additive_conflict_files ["CHANGELOG.md"]
  @resolver_witness_header "Harness resolver witness: "

  @typedoc "The settled run a landing job carries (built by the worker from Oban args)."
  @type request :: %{
          :project => Project.t(),
          :run_id => String.t(),
          :task_id => String.t(),
          :branch => String.t(),
          optional(:task_fingerprint) => String.t() | nil,
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

  See the module doc for the procedure and the outcome vocabulary.
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
  it re-fetches, rebases onto the current target, and pushes. The job is marked
  as an operator-invoked reland so a post-resolver conflict is retained and
  witnessed instead of inheriting the autonomous merge-train redispatch fallback.

  Mechanical by design: it asserts only the reviewer-approved precondition (the
  loaded record must have settled `:done` with `verdict: :approve` — a re-land
  pushes the branch with no re-verification, so an un-approved record is refused
  with `{:error, {:not_approved, _}}` and pushes nothing). It does **not** judge
  whether re-landing *now* is warranted — the caller (operator clicking the
  dashboard button, or an orchestrator) decides timing; harness only re-enqueues.
  """
  @spec enqueue(String.t()) ::
          {:ok, %{run_id: String.t(), task_id: String.t()}}
          | {:error, :not_found | {:not_approved, map()} | term()}
  def enqueue(run_id) when is_binary(run_id) do
    with {:ok, record} <- ResultStore.fetch_run_record(run_id),
         :ok <- ensure_approved(record),
         {:ok, project} <- ProjectRegistry.lookup(record.project_name),
         {:ok, _job} <- insert_landing(record, project) do
      {:ok, %{run_id: run_id, task_id: record.task_id}}
    end
  end

  # A re-land pushes the run's `harness/<run-id>` branch straight to the target
  # with NO re-verification — so it must assert the run was reviewer-approved
  # first (mirrors the auto-land path's `reason: :approved` gate). An approved run
  # settles `:done` with `verdict: :approve`; any other record (a `:reject`
  # verdict, a `:failed` state) is refused and pushes nothing. Mechanical: it
  # checks two persisted facts, it does not judge whether re-landing is warranted.
  @spec ensure_approved(LogRecord.t()) :: :ok | {:error, {:not_approved, map()}}
  defp ensure_approved(%LogRecord{state: :done, verdict: :approve}), do: :ok

  defp ensure_approved(%LogRecord{state: state, verdict: verdict}),
    do: {:error, {:not_approved, %{state: state, verdict: verdict}}}

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
      "task_fingerprint" => record.task_fingerprint,
      "agent" => to_string(record.agent),
      "reviewer" => reviewer_name(record.reviewer_adapter),
      "branch" => "harness/" <> record.run_id,
      "land_attempt" => 1,
      "manual_reland" => true
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
      with {:ok, integrated_tip} <- integrate(worktree, target, base_sha, request),
           {:ok, tip} <- rewrite_colliding_roadmap_task_ids(worktree, base_sha, integrated_tip),
           {:ok, pushed} <- push(repo, tip, target) do
        sync_local_target(repo, target, project, request)
        writeback(project, request, pushed)
        enqueue_audit(project, request, base_sha)
        prune_landed_run(repo, request)
        {:landed, pushed}
      else
        {:conflict, _output} = conflict -> conflict
        {:push_rejected, _output} = rejected -> rejected
        {:error, reason} -> {:error, reason}
      end

    cleanup(worktree)
    result
  end

  # sobelow_skip ["Traversal.FileModule"] — tasks_path is Path.join(worktree.path, "roadmap/tasks.toml")
  @spec rewrite_colliding_roadmap_task_ids(Worktree.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp rewrite_colliding_roadmap_task_ids(%Worktree{path: path}, base_sha, tip) do
    tasks_path = Path.join(path, "roadmap/tasks.toml")

    if File.regular?(tasks_path) do
      with {:ok, base_toml} <- base_tasks_toml(path, base_sha),
           {:ok, head_toml} <- File.read(tasks_path) do
        apply_task_id_rewrite(path, tasks_path, base_toml, head_toml, tip)
      end
    else
      {:ok, tip}
    end
  end

  @spec base_tasks_toml(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp base_tasks_toml(path, base_sha) do
    case Git.run(["show", "#{base_sha}:roadmap/tasks.toml"], path) do
      {:ok, toml} -> {:ok, toml}
      {:error, {:git_failed, _args, _status, _output}} -> {:ok, ""}
    end
  end

  # sobelow_skip ["Traversal.FileModule"] — tasks_path is the landing worktree's roadmap/tasks.toml
  @spec apply_task_id_rewrite(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  defp apply_task_id_rewrite(path, tasks_path, base_toml, head_toml, tip) do
    case TaskIdRewriter.rewrite_collisions(base_toml, head_toml) do
      :unchanged ->
        {:ok, tip}

      {:rewritten, rewritten, rewrites} ->
        with :ok <- File.write(tasks_path, rewritten),
             :ok <- render_roadmap(path, tasks_path),
             {:ok, rewritten_tip} <- commit_roadmap_rewrite(path) do
          Logger.info("harness lander: reassigned colliding roadmap task ids #{inspect(rewrites)}")
          {:ok, rewritten_tip}
        end
    end
  end

  @spec commit_roadmap_rewrite(String.t()) :: {:ok, String.t()} | {:error, term()}
  defp commit_roadmap_rewrite(path) do
    with {:ok, _added} <- Git.run(["add", "-A", "roadmap/tasks.toml", "ROADMAP.md", "roadmap/data.json"], path),
         {:ok, status} <- Git.run(["status", "--porcelain"], path),
         :ok <- ensure_roadmap_rewrite_changes(status),
         {:ok, _commit} <- git_commit(path, "roadmap: reassign colliding task ids") do
      head_sha(path)
    else
      {:error, reason} -> {:error, {:roadmap_rewrite_commit_failed, reason}}
    end
  end

  @spec ensure_roadmap_rewrite_changes(String.t()) :: :ok | {:error, :no_roadmap_rewrite_changes}
  defp ensure_roadmap_rewrite_changes(status) do
    if String.trim(status) == "", do: {:error, :no_roadmap_rewrite_changes}, else: :ok
  end

  @spec git_commit(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp git_commit(path, message) do
    Git.run(
      [
        "-c",
        "user.name=harness",
        "-c",
        "user.email=harness@localhost",
        "commit",
        "-q",
        "-m",
        message
      ],
      path
    )
  end

  @spec render_roadmap(String.t(), String.t()) :: :ok | {:error, term()}
  defp render_roadmap(path, tasks_path) do
    case System.cmd("rmap", ["render", "--tasks-path", tasks_path], cd: path, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:roadmap_render_failed, status, output}}
    end
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
  # worktree is left mid-rebase (markers in place); harness first tries a
  # mechanical union for configured additive-only files (e.g. CHANGELOG appends),
  # then gives a cross-family resolver agent a chance on any remaining conflicts.
  # Only if resolution fails do we abort and surface `{:conflict, _}` for the
  # resilience layer's re-dispatch.
  @spec rebase_onto(Worktree.t(), String.t(), String.t(), request()) ::
          {:ok, String.t()} | {:conflict, String.t()} | {:error, term()}
  defp rebase_onto(%Worktree{path: path} = worktree, origin_ref, base_sha, request) do
    case Git.run(["rebase", origin_ref], path) do
      {:ok, _output} -> head_sha(path)
      {:error, {:git_failed, _args, _status, output}} -> resolve_or_abort(worktree, base_sha, request, output)
    end
  end

  # On rebase conflict, first attempts a mechanical `git merge-file --union` for
  # any files in the configured additive set (default: CHANGELOG.md). Pure appends
  # on those files are resolved without an agent and the rebase continues. Remaining
  # conflicts (or union error) fall through to the cross-family resolver agent:
  # the agent edits the worktree (Resolver), then harness mechanically stages,
  # asserts zero leftover conflict markers, and continues the rebase. Any
  # failure — resolver unavailable, the agent declined, markers still present,
  # or `rebase --continue` rejecting — aborts the rebase, attaches a resolver
  # witness, and surfaces `{:conflict, _}` for the resilience layer. A still-
  # conflicted tree is never landed. No re-verification: the reviewer already
  # approved both sides.
  @spec resolve_or_abort(Worktree.t(), String.t(), request(), String.t()) ::
          {:ok, String.t()} | {:conflict, String.t()}
  defp resolve_or_abort(%Worktree{path: path} = worktree, base_sha, request, conflict_output) do
    OpsFeed.broadcast(Op.land_stage(request, :resolving))

    case resolve_additive_conflicts(path) do
      :resolved_all ->
        continue_mechanical_resolution(path, request, conflict_output)

      {:remaining, _files} ->
        resolve_with_agent(worktree, base_sha, request, conflict_output)

      {:error, reason} ->
        Logger.info("harness lander: additive conflict union failed for task #{request.task_id} (#{inspect(reason)})")
        resolve_with_agent(worktree, base_sha, request, conflict_output)
    end
  end

  @spec continue_mechanical_resolution(String.t(), request(), String.t()) :: {:ok, String.t()} | {:conflict, String.t()}
  defp continue_mechanical_resolution(path, request, conflict_output) do
    with :ok <- assert_resolved(path),
         {:ok, tip} <- continue_rebase(path) do
      Logger.info("harness lander: mechanically union-merged additive conflict for task #{request.task_id}")
      {:ok, tip}
    else
      {:error, reason} ->
        _ = Git.run(["rebase", "--abort"], path)
        {:conflict, witness_conflict(conflict_output, "mechanical additive union failed: #{inspect(reason)}")}
    end
  end

  @spec resolve_with_agent(Worktree.t(), String.t(), request(), String.t()) ::
          {:ok, String.t()} | {:conflict, String.t()}
  defp resolve_with_agent(%Worktree{path: path} = worktree, base_sha, request, conflict_output) do
    with :ok <- run_resolver(worktree, base_sha, request),
         :ok <- stage_all(path),
         :ok <- assert_resolved(path),
         {:ok, tip} <- continue_rebase(path) do
      Logger.info("harness lander: merge-resolver reconciled rebase conflict for task #{request.task_id}")
      {:ok, tip}
    else
      {:error, reason} ->
        _ = Git.run(["rebase", "--abort"], path)
        witness = resolver_witness(reason)

        Logger.info(
          "harness lander: merge-resolver fell back to re-dispatch for task #{request.task_id} (#{inspect(reason)})"
        )

        {:conflict, witness_conflict(conflict_output, witness)}
    end
  end

  @spec resolve_additive_conflicts(String.t()) :: :resolved_all | {:remaining, [String.t()]} | {:error, term()}
  defp resolve_additive_conflicts(path) do
    with {:ok, files} <- Git.conflicted_files(path),
         :ok <- union_additive_files(path, Enum.filter(files, &additive_conflict_file?/1)),
         {:ok, remaining} <- Git.conflicted_files(path) do
      if remaining == [], do: :resolved_all, else: {:remaining, remaining}
    end
  end

  @spec union_additive_files(String.t(), [String.t()]) :: :ok | {:error, term()}
  defp union_additive_files(path, files) do
    Enum.reduce_while(files, :ok, fn file, :ok ->
      case union_additive_file(path, file) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:additive_union_failed, file, reason}}}
      end
    end)
  end

  @spec additive_conflict_file?(String.t()) :: boolean()
  defp additive_conflict_file?(file), do: file in additive_conflict_files()

  @spec additive_conflict_files() :: [String.t()]
  defp additive_conflict_files do
    :harness
    |> Application.get_env(:lander, [])
    |> Keyword.get(:additive_conflict_files, @default_additive_conflict_files)
  end

  @spec union_additive_file(String.t(), String.t()) :: :ok | {:error, term()}
  defp union_additive_file(path, file) do
    tmp_dir = Path.join(System.tmp_dir!(), "harness-union-#{System.unique_integer([:positive])}")

    try do
      with :ok <- File.mkdir_p(tmp_dir),
           {:ok, base} <- staged_blob(path, file, 1),
           {:ok, ours} <- staged_blob(path, file, 2),
           {:ok, theirs} <- staged_blob(path, file, 3),
           :ok <- write_union_inputs(tmp_dir, base, ours, theirs),
           :ok <- merge_union(path, tmp_dir),
           {:ok, merged} <- File.read(Path.join(tmp_dir, "ours")),
           :ok <- File.write(Path.join(path, file), merged),
           {:ok, _output} <- Git.run(["add", "--", file], path) do
        :ok
      end
    after
      _ = File.rm_rf(tmp_dir)
    end
  end

  @spec staged_blob(String.t(), String.t(), 1 | 2 | 3) :: {:ok, String.t()} | {:error, term()}
  defp staged_blob(path, file, stage), do: Git.run(["show", ":#{stage}:#{file}"], path)

  @spec write_union_inputs(String.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  defp write_union_inputs(tmp_dir, base, ours, theirs) do
    with :ok <- File.write(Path.join(tmp_dir, "base"), base),
         :ok <- File.write(Path.join(tmp_dir, "ours"), ours) do
      File.write(Path.join(tmp_dir, "theirs"), theirs)
    end
  end

  @spec merge_union(String.t(), String.t()) :: :ok | {:error, term()}
  defp merge_union(path, tmp_dir) do
    args = ["merge-file", "--union", Path.join(tmp_dir, "ours"), Path.join(tmp_dir, "base"), Path.join(tmp_dir, "theirs")]

    case System.cmd("git", args, cd: path, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:merge_file_failed, status, output}}
    end
  end

  @spec resolver_witness(term()) :: String.t()
  defp resolver_witness({:unresolved_markers, _output}), do: "agent spawned; unresolved conflict markers remain"
  defp resolver_witness({:stage_failed, reason}), do: "agent spawned; staging failed: #{inspect(reason)}"

  defp resolver_witness({:rebase_continue_failed, reason}),
    do: "agent spawned; rebase continue failed: #{inspect(reason)}"

  defp resolver_witness(reason), do: "selection/spawn failed: #{inspect(reason)}"

  @spec witness_conflict(String.t(), String.t()) :: String.t()
  defp witness_conflict(output, witness), do: output <> "\n\n" <> @resolver_witness_header <> witness <> "\n"

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
    persist_landed_sha(request.run_id, sha)

    case Roadmap.mark_landed(request.task_id,
           project: project,
           sha: sha,
           task_fingerprint: request[:task_fingerprint],
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

  @spec persist_landed_sha(String.t(), String.t()) :: :ok
  defp persist_landed_sha(run_id, sha) do
    case mark_landed_verified(run_id, sha) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "harness lander: run-record landed_sha writeback failed for run #{run_id} (landed #{sha}): #{inspect(reason)}"
        )

        :ok
    end
  end

  @spec mark_landed_verified(String.t(), String.t()) :: :ok | {:error, term()}
  defp mark_landed_verified(run_id, sha) do
    mark_landed_verified(run_id, sha, ResultStore.configured())
  end

  @spec mark_landed_verified(String.t(), String.t(), ResultStore.store()) :: :ok | {:error, term()}
  defp mark_landed_verified(_run_id, _sha, store) when store in [false, nil], do: :ok

  defp mark_landed_verified(run_id, sha, store) do
    with :ok <- ResultStore.mark_landed(run_id, sha, store),
         {:error, :landed_sha_missing} <- verify_landed_sha(run_id, sha, store),
         :ok <- ResultStore.mark_landed(run_id, sha, store) do
      verify_landed_sha(run_id, sha, store)
    else
      :ok -> :ok
      {:error, _reason} = error -> error
    end
  end

  @spec verify_landed_sha(String.t(), String.t(), ResultStore.store()) :: :ok | {:error, term()}
  defp verify_landed_sha(run_id, sha, store) do
    case ResultStore.list_run_records(store, run_id: run_id) do
      {:ok, [%LogRecord{landed_sha: ^sha} | _]} -> :ok
      {:ok, [%LogRecord{landed_sha: nil} | _]} -> {:error, :landed_sha_missing}
      {:ok, [%LogRecord{landed_sha: other} | _]} -> {:error, {:landed_sha_mismatch, other}}
      {:ok, []} -> {:error, :run_record_not_found}
      {:error, _reason} = error -> error
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
    # Oban/repo not running (RuntimeError) or a DB insert failure → log, never
    # un-land. A genuine code bug stays unlisted so it crashes rather than hiding.
    error in [
      RuntimeError,
      DBConnection.ConnectionError,
      DBConnection.OwnershipError,
      Postgrex.Error,
      Ecto.ConstraintError,
      Ecto.QueryError,
      ArgumentError
    ] ->
      log_audit_enqueue_failure(project, error)
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

  @spec prune_landed_run(String.t(), request()) :: :ok
  defp prune_landed_run(repo, request) do
    # The push is the point of no return. `Worktree.cleanup_for_run/2` carries
    # the Harness.Run.Registry liveness guard, so a still-registered run keeps
    # its branch and implementer worktree even on this best-effort cleanup path.
    case Worktree.cleanup_for_run(repo, request.run_id) do
      :ok ->
        warn_on_prune_leftovers(repo, request)
        :ok

      {:error, reason} ->
        Logger.warning("harness lander: run cleanup failed after landing run #{request.run_id}: #{inspect(reason)}")

        :ok
    end
  end

  @spec warn_on_prune_leftovers(String.t(), request()) :: :ok
  defp warn_on_prune_leftovers(repo, request) do
    if branch_exists?(repo, request.branch) or File.exists?(run_worktree_path(request)) do
      Logger.warning("harness lander: run cleanup left branch or worktree after landing run #{request.run_id}")
    end

    :ok
  end

  @spec branch_exists?(String.t(), String.t()) :: boolean()
  defp branch_exists?(repo, branch) do
    match?({:ok, _}, Git.run(["show-ref", "--verify", "--quiet", "refs/heads/" <> branch], repo))
  end

  @spec run_worktree_path(request()) :: String.t()
  defp run_worktree_path(request) do
    Path.join([Worktree.base_dir(), request.project.name, request.run_id])
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
