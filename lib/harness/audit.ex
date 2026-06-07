defmodule Harness.Audit do
  @moduledoc """
  Post-merge audit pass: a third-family agent reviews commits that already
  landed on a project's target branch and fixes hygiene forward.

  The final stage of the agent-gate workflow (worktree → implementer AI →
  reviewer AI → MERGE → **audit AI**). After `Harness.Lander` pushes an approved
  run, it enqueues `Harness.Audit.Worker`, which calls `run/1`:

    1. `git fetch origin` and check `origin/<target>` out into a fresh detached
       worktree,
    2. compute the unaudited range mechanically — from the last `audit(...)`
       commit on the branch (falling back to the pre-land base the lander
       recorded) to `HEAD`; an empty range is a no-op,
    3. pick the audit agent: the first dispatchable adapter outside both the
       implementer's and the reviewer's families,
    4. run it — the agent reviews the range, fixes hygiene inline, commits
       `audit(<sha>): ...` with a `.audit/<sha>.md` report, and writes a
       `.harness/audit.json` summary harness logs,
    5. fast-forward-push whatever the agent committed back to the target.

  Clean audits (`:no_changes`) intentionally do not write empty `audit(...)`
  marker commits to the shared branch. Instead, harness records the audited tip
  in the shared settings store and consults that watermark alongside the last
  reachable `audit(...)` commit when framing the next range.

  ## Best-effort, never a gate

  The audit never blocks, reverts, or unmerges a landed run. Every degenerate
  path — no third agent family installed, the agent committed nothing, the
  target advanced under the push — degrades to a logged no-op. The next land
  enqueues the next audit, which covers any range this one missed.
  """

  alias Harness.Agent.Settings, as: AgentSettings
  alias Harness.AgentAdapter.Driver
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Outcome
  alias Harness.AgentRegistry
  alias Harness.Git
  alias Harness.Project
  alias Harness.ResultStore
  alias Harness.SettingsStore
  alias Harness.Worktree

  require Logger

  @audit_report_path ".harness/audit.json"
  @watermark_store_key :audit
  @rejection_history_limit 20
  @rejection_summary_limit 500

  @typedoc """
  The audit request a worker builds from Oban args.

  `:auditor` pins the audit agent to an explicit adapter module, bypassing
  third-family selection (mirrors `Harness.AuditReview`'s `:grader` opt — test
  stubs and config-driven overrides without expanding the registry).
  `:auditor_opts` rides into the invocation's `adapter_opts`.
  """
  @type request :: %{
          :project => Project.t(),
          :base_sha => String.t(),
          optional(:implementer) => String.t() | nil,
          optional(:reviewer) => String.t() | nil,
          optional(:auditor) => module() | nil,
          optional(:auditor_opts) => keyword(),
          optional(:result_store) => ResultStore.store()
        }

  @typedoc """
  The structured result of an audit attempt.

    * `{:audited, sha}` — the agent committed fixes/report and the push landed.
    * `:noop` — the range was already audited (nothing newer than the last
      `audit(...)` commit).
    * `:no_changes` — the agent ran but committed nothing.
    * `{:push_rejected, output}` — the target advanced under us; the audit work
      is dropped (the next land's audit covers the range again).
    * `{:skipped, reason}` — the project can't be audited (GitHub source, no
      target branch, no third-family agent available).
    * `{:error, reason}` — a mechanical step failed; the worker may retry.
  """
  @type outcome ::
          {:audited, String.t()}
          | :noop
          | :no_changes
          | {:push_rejected, String.t()}
          | {:skipped, term()}
          | {:error, term()}

  @doc """
  Audits the unaudited range on `request`'s project target branch.

  See the module doc for the procedure. Idempotent: re-running against an
  already-audited tip is a `:noop`.
  """
  @spec run(request()) :: outcome()
  def run(%{project: %Project{} = project, base_sha: base_sha} = request) when is_binary(base_sha) do
    with {:ok, repo} <- Project.local_repo_path(project),
         {:ok, target} <- target_branch(project),
         :ok <- fetch_origin(repo),
         {:ok, worktree} <- checkout(repo, target) do
      audit_in_worktree(worktree, repo, target, project, request)
    end
  end

  @spec audit_in_worktree(Worktree.t(), String.t(), String.t(), Project.t(), request()) :: outcome()
  defp audit_in_worktree(%Worktree{} = worktree, repo, target, project, request) do
    result =
      case unaudited_range(worktree.path, request.base_sha, project, target) do
        {:ok, :empty} ->
          :noop

        {:ok, range} ->
          # The auditor runs the project's checks, so warm its fresh worktree the
          # same way a run worktree is warmed — seed deps/_build/PLT from the
          # parent so the auditor doesn't cold-compile + cold-build the PLT. Only
          # done when there's a range to audit; a :noop checks nothing.
          :ok = Worktree.warm(worktree)
          run_auditor(worktree, repo, target, project, request, range)

        {:error, reason} ->
          {:error, reason}
      end

    cleanup(worktree)
    result
  end

  # The range is mechanical: the newest reachable audit watermark (an audit(...)
  # commit or local clean-audit marker), else the pre-land base the lander
  # recorded.
  @spec unaudited_range(String.t(), String.t(), Project.t(), String.t()) ::
          {:ok, :empty | %{base: String.t(), log: String.t(), short_sha: String.t()}} | {:error, term()}
  defp unaudited_range(path, fallback_base, project, target) do
    with {:ok, base} <- audit_base(path, fallback_base, project, target),
         {:ok, count} <- commit_count(path, base) do
      if count == 0, do: {:ok, :empty}, else: describe_range(path, base)
    end
  end

  @spec audit_base(String.t(), String.t(), Project.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp audit_base(path, fallback_base, project, target) do
    with {:ok, audit_marker} <- audit_marker_base(path) do
      path
      |> reachable_bases([audit_marker, watermark(project, target)])
      |> newest_base(path, fallback_base)
    end
  end

  @spec audit_marker_base(String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  defp audit_marker_base(path) do
    case Git.run(["log", "--grep", "^audit(", "-1", "--format=%H", "HEAD"], path) do
      {:ok, output} ->
        case String.trim(output) do
          "" -> {:ok, nil}
          sha -> {:ok, sha}
        end

      {:error, reason} ->
        {:error, {:audit_base_failed, reason}}
    end
  end

  @spec reachable_bases(String.t(), [String.t() | nil]) :: [String.t()]
  defp reachable_bases(path, candidates) do
    candidates
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.filter(&reachable?(path, &1))
  end

  @spec reachable?(String.t(), String.t()) :: boolean()
  defp reachable?(path, sha) do
    match?({:ok, _output}, Git.run(["merge-base", "--is-ancestor", sha, "HEAD"], path))
  end

  @spec newest_base([String.t()], String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp newest_base([], _path, fallback_base), do: {:ok, fallback_base}
  defp newest_base([base], _path, _fallback_base), do: {:ok, base}

  defp newest_base(bases, path, _fallback_base) do
    case pick_newest_base(bases, path) do
      {:ok, base} -> {:ok, base}
      :error -> {:error, {:audit_base_failed, :no_reachable_base}}
    end
  end

  # Among ancestor candidates, the newest watermark is closest to HEAD (smallest
  # base..HEAD count). `git log -1 sha1 sha2` does NOT pick the newest.
  @spec pick_newest_base([String.t()], String.t()) :: {:ok, String.t()} | :error
  defp pick_newest_base(bases, path) do
    bases
    |> Enum.reduce_while(nil, fn base, acc ->
      case commit_count(path, base) do
        {:ok, count} -> {:cont, prefer_newer_base(base, count, acc)}
        {:error, _} -> {:cont, acc}
      end
    end)
    |> case do
      {base, _} -> {:ok, base}
      nil -> :error
    end
  end

  @spec prefer_newer_base(String.t(), non_neg_integer(), {String.t(), non_neg_integer()} | nil) ::
          {String.t(), non_neg_integer()}
  defp prefer_newer_base(base, count, nil), do: {base, count}
  defp prefer_newer_base(base, count, {_, best}) when count < best, do: {base, count}
  defp prefer_newer_base(_base, _count, acc), do: acc

  @spec commit_count(String.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp commit_count(path, base) do
    case Git.run(["rev-list", "--count", base <> "..HEAD"], path) do
      {:ok, output} -> {:ok, output |> String.trim() |> String.to_integer()}
      {:error, reason} -> {:error, {:range_check_failed, reason}}
    end
  end

  @spec describe_range(String.t(), String.t()) ::
          {:ok, %{base: String.t(), log: String.t(), short_sha: String.t()}} | {:error, term()}
  defp describe_range(path, base) do
    with {:ok, log} <- Git.run(["log", "--oneline", base <> "..HEAD"], path),
         {:ok, short} <- Git.run(["rev-parse", "--short", "HEAD"], path) do
      {:ok, %{base: base, log: String.trim_trailing(log), short_sha: String.trim(short)}}
    end
  end

  @spec run_auditor(Worktree.t(), String.t(), String.t(), Project.t(), request(), map()) :: outcome()
  defp run_auditor(worktree, repo, target, project, request, range) do
    with {:ok, auditor} <- select_auditor(request),
         {:ok, %Outcome{}} <- Driver.run(auditor, invocation(worktree, target, project, request, range), []),
         {:ok, head} <- head_sha(worktree.path) do
      log_audit_report(worktree.path)
      outcome = push_if_advanced(repo, worktree, target, head)
      record_watermark(project, target, head, outcome)
      outcome
    end
  end

  @doc false
  # An explicit :auditor in the request wins (test stubs / config overrides);
  # otherwise: first dispatchable adapter outside both the implementer's and the
  # reviewer's families — the third family. None available → skip (best-effort).
  # `@doc false` (not `defp`) so the cross-family + reviewer-eligibility invariant
  # is unit-testable, mirroring `Harness.Lander.Resolver.select_resolver/2`.
  @spec select_auditor(request()) :: {:ok, module()} | {:skipped, :no_audit_agent}
  def select_auditor(%{auditor: auditor}) when is_atom(auditor) and not is_nil(auditor), do: {:ok, auditor}

  def select_auditor(request) do
    # Normalize both sides to strings: the real Oban-worker path passes JSON
    # string args, but atom-keyed callers (the `@doc false` unit surface, future
    # in-process callers) would otherwise no-match the `in` test and let the
    # reviewer's own family audit its own land.
    excluded =
      [request[:implementer], request[:reviewer]]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)

    AgentRegistry.agents()
    |> Enum.reject(fn {agent, _module} -> to_string(agent) in excluded end)
    |> Enum.find_value(fn {_agent, module} ->
      if auditor_dispatchable?(module), do: {:ok, module}
    end)
    |> case do
      {:ok, module} -> {:ok, module}
      nil -> {:skipped, :no_audit_agent}
    end
  end

  @spec auditor_dispatchable?(module()) :: boolean()
  defp auditor_dispatchable?(module) do
    AgentRegistry.available?(module) and
      AgentRegistry.installed?(module) and
      auditor_eligible?(module)
  end

  # The auditor commits and ff-pushes to the shared target branch unsupervised —
  # a *higher*-trust role than the reviewer gate. So it requires the same
  # `reviewer_eligible?` trust flag the reviewer and resolver demand (not just
  # `enabled?`): an agent we won't trust to *gate* a run must not be trusted to
  # autonomously *write to* the target branch. An unresolvable module (test
  # doubles via the explicit `:auditor` override) stays permissive.
  @spec auditor_eligible?(module()) :: boolean()
  defp auditor_eligible?(module) do
    case AgentRegistry.agent_for_module(module) do
      {:ok, agent} -> AgentSettings.enabled?(agent) and AgentSettings.reviewer_eligible?(agent)
      {:error, _reason} -> true
    end
  end

  @spec invocation(Worktree.t(), String.t(), Project.t(), request(), map()) :: Invocation.t()
  defp invocation(worktree, target, project, request, range) do
    %Invocation{
      prompt: audit_prompt(target, project, range, rejection_history(project, request)),
      cwd: worktree.path,
      task_id: "audit-#{project.name}-#{range.short_sha}",
      permission_mode: :autonomous,
      adapter_opts: request[:auditor_opts] || []
    }
  end

  # Recent reviewer rejections for this project, from the run-records store. The
  # auditor (an AI) correlates them against the landed range to flag FALSE
  # rejections — the reviewer-quality feedback loop. Mechanical read only; a
  # disabled or empty store yields the "(none ...)" placeholder, never a crash.
  @spec rejection_history(Project.t(), request()) :: String.t()
  defp rejection_history(project, request) do
    store = Map.get(request, :result_store, ResultStore.configured())

    case ResultStore.list_run_records(store,
           verdict: :reject,
           project_name: project.name,
           limit: @rejection_history_limit
         ) do
      {:ok, [_ | _] = records} -> Enum.map_join(records, "\n", &rejection_line/1)
      _empty_or_error -> "(no reviewer rejections recorded for this project)"
    end
  end

  @spec rejection_line(Harness.Run.LogRecord.t()) :: String.t()
  defp rejection_line(record) do
    "- task #{record.task_id} (run #{record.run_id}): #{rejection_summary(record.review_report)}"
  end

  @spec rejection_summary(String.t() | nil) :: String.t()
  defp rejection_summary(report) when is_binary(report) do
    report |> String.slice(0, @rejection_summary_limit) |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  defp rejection_summary(_report), do: "(no report)"

  # The audit agent's instructions. The judgment (what is a hygiene issue, what
  # matters, what to fix) lives entirely in the agent; harness only frames the
  # range and pushes whatever it commits.
  @spec audit_prompt(String.t(), Project.t(), map(), String.t()) :: String.t()
  defp audit_prompt(target, project, range, rejections) do
    """
    You are the post-merge audit agent for project #{project.name} — a best-effort hygiene pass over
    commits that already landed on `#{target}`. The merge is settled: you never revert, unmerge, or
    block anything. You fix forward.

    Landed range to audit (already merged):
    #{range.log}

    Your job, in order:
    1. Review the range for hygiene: dead code, missing or stale docs, CHANGELOG gaps, leftover debug
       output, broken project conventions, inconsistent naming. Judge what matters — finding nothing
       is a valid outcome.
    2. Fix what you find — your own edits. Run the project's checks if your fixes touch code (hint below).
    3. Write an audit report to `.audit/#{range.short_sha}.md`: what you reviewed, what you found, what
       you fixed. A clean range still gets a report ("clean").
    4. Commit the report plus your fixes as ONE commit with subject: `audit(#{range.short_sha}): <summary>`
       — this commit is also the marker the next audit uses to know where this one stopped.
    5. Write a machine-readable summary to `#{@audit_report_path}`:
       {"findings": <count>, "fixed": <count>, "report": "<one-paragraph summary>"}
       Do NOT commit this file — it is harness-internal.

    Reviewer-quality feedback loop — recent reviewer rejections for this project (a cross-family
    reviewer is THE gate, and rejection is rare by design). If a task in the landed range above also
    appears here and the work that actually landed looks sound, that rejection may have been a FALSE
    rejection — note it in your `.audit/#{range.short_sha}.md` report. This only feeds the report; you
    still never revert or block.
    #{rejections}

    Project check hint (run yourself if needed; judge the output):
    #{project.check_command || "(none provided)"}
    """
  end

  # Best-effort visibility: surface the agent's machine-readable summary in the
  # logs. A missing or malformed file is fine — the .audit/<sha>.md commit is
  # the durable report.
  # sobelow_skip ["Traversal.FileModule"]
  @spec log_audit_report(String.t()) :: :ok
  defp log_audit_report(worktree_path) do
    with {:ok, raw} <- File.read(Path.join(worktree_path, @audit_report_path)),
         {:ok, report} <- Jason.decode(raw) do
      Logger.info("harness audit: #{inspect(report)}")
    else
      _missing_or_malformed -> :ok
    end

    :ok
  end

  @spec push_if_advanced(String.t(), Worktree.t(), String.t(), String.t()) :: outcome()
  defp push_if_advanced(_repo, %Worktree{base_sha: base_sha}, _target, head) when head == base_sha, do: :no_changes

  defp push_if_advanced(repo, _worktree, target, head) do
    case Git.run(["push", "origin", head <> ":refs/heads/" <> target], repo) do
      {:ok, _output} ->
        {:audited, head}

      {:error, {:git_failed, _args, _status, output}} ->
        Logger.warning("harness audit: push rejected (target advanced); dropping audit work: #{output}")

        {:push_rejected, output}
    end
  end

  @spec record_watermark(Project.t(), String.t(), String.t(), outcome()) :: :ok
  defp record_watermark(project, target, head, :no_changes) do
    persist_watermark(project, target, head)
  end

  defp record_watermark(project, target, head, {:audited, _sha}) do
    persist_watermark(project, target, head)
  end

  defp record_watermark(_project, _target, _head, _outcome), do: :ok

  @spec watermark(Project.t(), String.t()) :: String.t() | nil
  defp watermark(%Project{name: name}, target) do
    with {:ok, record} when is_map(record) <- fetch_watermarks(),
         project_record when is_map(project_record) <- Map.get(record, name),
         sha when is_binary(sha) and sha != "" <- Map.get(project_record, target) do
      sha
    else
      _missing_or_malformed -> nil
    end
  end

  @spec persist_watermark(Project.t(), String.t(), String.t()) :: :ok
  defp persist_watermark(%Project{name: name}, target, sha) do
    if watermark_persistence_enabled?() do
      record = put_watermark(read_watermarks(), name, target, sha)

      case SettingsStore.put(@watermark_store_key, record) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("harness audit: failed to persist audit watermark for #{name}/#{target}: #{inspect(reason)}")

          :ok
      end
    else
      :ok
    end
  end

  @spec fetch_watermarks() :: {:ok, term()} | :not_found | {:error, term()}
  defp fetch_watermarks do
    if watermark_persistence_enabled?(), do: SettingsStore.fetch(@watermark_store_key), else: :not_found
  end

  @spec read_watermarks() :: map()
  defp read_watermarks do
    case fetch_watermarks() do
      {:ok, record} when is_map(record) -> record
      _missing_or_malformed -> %{}
    end
  end

  @spec put_watermark(map(), String.t(), String.t(), String.t()) :: map()
  defp put_watermark(record, project_name, target, sha) do
    project_record =
      case Map.get(record, project_name) do
        map when is_map(map) -> map
        _other -> %{}
      end

    Map.put(record, project_name, Map.put(project_record, target, sha))
  end

  @spec watermark_persistence_enabled?() :: boolean()
  defp watermark_persistence_enabled?, do: Application.get_env(:harness, :repo_enabled, true)

  @spec cleanup(Worktree.t()) :: :ok
  defp cleanup(%Worktree{} = worktree) do
    case Worktree.remove(worktree) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("harness audit: failed to remove audit worktree #{worktree.path}: #{inspect(reason)}")

        :ok
    end
  end

  @spec target_branch(Project.t()) :: {:ok, String.t()} | {:skipped, :no_target_branch}
  defp target_branch(%Project{target_branch: tb}) when is_binary(tb) and tb != "", do: {:ok, tb}
  defp target_branch(%Project{}), do: {:skipped, :no_target_branch}

  @spec fetch_origin(String.t()) :: :ok | {:error, term()}
  defp fetch_origin(repo) do
    case Git.run(["fetch", "origin"], repo) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:fetch_failed, reason}}
    end
  end

  @spec checkout(String.t(), String.t()) :: {:ok, Worktree.t()} | {:error, term()}
  defp checkout(repo, target) do
    case Worktree.checkout_existing(repo, "origin/" <> target) do
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
