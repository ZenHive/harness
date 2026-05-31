defmodule Harness.Lander do
  @moduledoc """
  Autonomous merge-train: lands an approved run onto a project's target branch.

  When a run settles green **and** clears the semantic gate (`landing_policy:
  :auto`), `Harness.Run` enqueues a landing job on the project's serialized
  `landing_<name>` Oban queue (limit 1, so one approved run lands at a time per
  project). `Harness.Lander.Worker` resolves the project and calls `land/1`,
  which:

    1. `git fetch origin`,
    2. checks out the settled run's `harness/<run-id>` branch in a fresh
       worktree and, if `origin/<target>` has moved past it, rebases onto it,
    3. **re-verifies the integrated state** with the project's check stack —
       the merge is only kept if the integrated tree is still green,
    4. fast-forward-pushes the verified tip to `origin/<target_branch>` (never
       `--force`; the operator's local checkout is untouched — they `git pull`),
    5. writes the outcome back to rmap (`done` + `verified` + `shipped_in`).

  ## Land mechanism: remote fast-forward push

  Landing is a ff-only `git push origin <tip>:refs/heads/<target>`. The push
  target is the *remote* branch, so harness never moves a locally-checked-out
  ref (which would desync the operator's working tree). `shipped_in` is the
  pushed SHA.

  ## Failure routing (Task 101 seam)

  This is the happy-path lander. A non-`:landed` outcome — `{:post_merge_red,
  verdict}` (integrated tree failed re-verification), `{:conflict, output}`
  (rebase hit a conflict), `{:push_rejected, output}` (the target advanced under
  us) — **retains the branch, does not push or write back, and returns the
  structured tuple.** Post-merge repair, conflict redispatch, and a blocked
  sink are Task 101's job; they plug into these tuples. `{:skipped, reason}`
  covers a project the lander can't act on yet (e.g. a `{:github, _}` source).
  """

  alias Harness.Git
  alias Harness.Project
  alias Harness.Roadmap
  alias Harness.Verification
  alias Harness.Verification.Verdict
  alias Harness.Worktree

  require Logger

  @typedoc "The settled run a landing job carries (built by the worker from Oban args)."
  @type request :: %{
          :project => Project.t(),
          :run_id => String.t(),
          :task_id => String.t(),
          :branch => String.t(),
          optional(:agent) => atom() | String.t() | nil
        }

  @typedoc "The structured result of a land attempt."
  @type outcome ::
          {:landed, String.t()}
          | {:post_merge_red, Verdict.t()}
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
         {:ok, worktree} <- checkout(repo, branch) do
      land_in_worktree(worktree, repo, target, project, request)
    end
  end

  @spec land_in_worktree(Worktree.t(), String.t(), String.t(), Project.t(), request()) :: outcome()
  defp land_in_worktree(%Worktree{} = worktree, repo, target, project, request) do
    result =
      with {:ok, tip} <- integrate(worktree, target),
           {:ok, verdict} <- reverify(worktree, project),
           :ok <- ensure_passed(verdict),
           {:ok, pushed} <- push(repo, tip, target) do
        writeback(project, request, pushed)
        {:landed, pushed}
      else
        {:conflict, _output} = conflict -> conflict
        {:post_merge_red, _verdict} = red -> red
        {:push_rejected, _output} = rejected -> rejected
        {:error, reason} -> {:error, reason}
      end

    cleanup(worktree)
    result
  end

  # origin/<target> already an ancestor of the branch tip -> ff-able as-is.
  # Otherwise the target moved, so rebase the branch onto it; a rebase that
  # hits a conflict is aborted and surfaced for Task 101.
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

  @spec reverify(Worktree.t(), Project.t()) :: {:ok, Verdict.t()} | {:error, term()}
  defp reverify(%Worktree{path: path}, %Project{check_stacks: stacks}) do
    Verification.run(path, check_stacks: stacks)
  end

  @spec ensure_passed(Verdict.t()) :: :ok | {:post_merge_red, Verdict.t()}
  defp ensure_passed(%Verdict{} = verdict) do
    if Verdict.passed?(verdict), do: :ok, else: {:post_merge_red, verdict}
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

  @spec delivered_by(atom() | String.t() | nil) :: String.t() | nil
  defp delivered_by(nil), do: nil
  defp delivered_by(agent) when is_binary(agent), do: agent
  defp delivered_by(agent) when is_atom(agent), do: Atom.to_string(agent)

  @spec implemented_text(request(), String.t()) :: String.t()
  defp implemented_text(request, sha) do
    by = if agent = request[:agent], do: "by #{agent} ", else: ""
    "Landed #{by}via merge-train; verified green post-integration (run #{request.run_id}, #{sha})."
  end

  @spec cleanup(Worktree.t()) :: :ok
  defp cleanup(%Worktree{} = worktree) do
    case Worktree.remove(worktree) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("harness lander: failed to remove re-verify worktree #{worktree.path}: #{inspect(reason)}")

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
