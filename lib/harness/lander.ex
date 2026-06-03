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
       the operator's local checkout is untouched — they `git pull`),
    4. writes the outcome back to rmap (`done` + `verified` + `shipped_in`),
    5. enqueues a post-merge audit job (`Harness.Audit.Worker`) for the landed
       range — best-effort, never blocks the land.

  There is **no re-verification step**: the reviewer AI already gated the work
  (it ran the project's checks itself); the lander is pure git mechanics. The
  post-merge audit agent is the safety net for integration drift.

  ## Land mechanism: remote fast-forward push

  Landing is a ff-only `git push origin <tip>:refs/heads/<target>`. The push
  target is the *remote* branch, so harness never moves a locally-checked-out
  ref (which would desync the operator's working tree). `shipped_in` is the
  pushed SHA.

  ## Failure routing (Task 101 seam)

  This is the happy-path lander. A non-`:landed` outcome — `{:conflict, output}`
  (rebase hit a conflict), `{:push_rejected, output}` (the target advanced under
  us) — **retains the branch, does not push or write back, and returns the
  structured tuple.** Conflict redispatch and a blocked sink are
  `Harness.Lander.Resilience`'s job; they plug into these tuples.
  `{:skipped, reason}` covers a project the lander can't act on yet (e.g. a
  `{:github, _}` source).
  """

  alias Harness.Audit.Worker, as: AuditWorker
  alias Harness.Git
  alias Harness.Oban, as: HarnessOban
  alias Harness.Project
  alias Harness.Roadmap
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
    with {:ok, repo} <- repo_path(project),
         {:ok, target} <- target_branch(project),
         :ok <- fetch_origin(repo),
         {:ok, base_sha} <- remote_target_sha(repo, target),
         {:ok, worktree} <- checkout(repo, branch) do
      land_in_worktree(worktree, repo, target, base_sha, project, request)
    end
  end

  @spec land_in_worktree(Worktree.t(), String.t(), String.t(), String.t(), Project.t(), request()) :: outcome()
  defp land_in_worktree(%Worktree{} = worktree, repo, target, base_sha, project, request) do
    result =
      with {:ok, tip} <- integrate(worktree, target),
           {:ok, pushed} <- push(repo, tip, target) do
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
  # hits a conflict is aborted and surfaced for the resilience layer.
  @spec integrate(Worktree.t(), String.t()) ::
          {:ok, String.t()} | {:conflict, String.t()} | {:error, term()}
  defp integrate(%Worktree{path: path}, target) do
    origin_ref = "origin/" <> target

    case Git.run(["merge-base", "--is-ancestor", origin_ref, "HEAD"], path) do
      {:ok, _output} -> head_sha(path)
      {:error, {:git_failed, _args, 1, _output}} -> rebase_onto(path, origin_ref)
      {:error, reason} -> {:error, {:ancestry_check_failed, reason}}
    end
  end

  @spec rebase_onto(String.t(), String.t()) ::
          {:ok, String.t()} | {:conflict, String.t()} | {:error, term()}
  defp rebase_onto(path, origin_ref) do
    case Git.run(["rebase", origin_ref], path) do
      {:ok, _output} ->
        head_sha(path)

      {:error, {:git_failed, _args, _status, output}} ->
        _ = Git.run(["rebase", "--abort"], path)
        {:conflict, output}
    end
  end

  @spec push(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:push_rejected, String.t()} | {:error, term()}
  defp push(repo, tip, target) do
    case Git.run(["push", "origin", tip <> ":refs/heads/" <> target], repo) do
      {:ok, _output} ->
        {:ok, tip}

      {:error, {:git_failed, _args, _status, output}} ->
        if non_fast_forward?(output),
          do: {:push_rejected, output},
          else: {:error, {:push_failed, output}}
    end
  end

  @spec non_fast_forward?(String.t()) :: boolean()
  defp non_fast_forward?(output) do
    String.contains?(output, "non-fast-forward") or
      String.contains?(output, "fetch first") or
      String.contains?(output, "[rejected]")
  end

  # The push succeeded, so the code IS landed; a writeback failure (e.g. rmap's
  # --shipped-in flag not yet present) is logged but never un-lands the merge.
  @spec writeback(Project.t(), request(), String.t()) :: :ok
  defp writeback(%Project{} = project, request, sha) do
    case Roadmap.mark_landed(request.task_id,
           root: project.roadmap_path,
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

  @spec repo_path(Project.t()) :: {:ok, String.t()} | {:skipped, :github_source}
  defp repo_path(%Project{source: {:local, _}} = project), do: {:ok, Project.repo_path(project)}
  defp repo_path(%Project{source: {:github, _}}), do: {:skipped, :github_source}

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
