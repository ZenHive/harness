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
       `.harness/audit.json` summary harness logs (including an agent-reported
       `cold_check` fact from a clean build in the intentionally un-warmed tree),
    5. fast-forward-push whatever the agent committed back to the target.

  The audit worktree is **not** warmed (`Worktree.warm/2` is skipped). The audit
  agent runs the project's `check_command` in that cold tree and reports
  `cold_check` in `.harness/audit.json`. Harness persists that fact on the run
  record; a reported red files a blocked follow-up task and notifies — never a
  revert, unmerge, or gate. Harness never shells out the build or reads an exit
  code.

  Clean audits (`:no_changes`) intentionally do not write empty `audit(...)`
  marker commits to the shared branch. Instead, harness records the audited tip
  in the settings store and consults that watermark alongside the last reachable
  `audit(...)` commit when framing the next range.

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
  alias Harness.Artifact
  alias Harness.Config
  alias Harness.Dashboard.OpsFeed
  alias Harness.Dashboard.OpsFeed.Op
  alias Harness.Git
  alias Harness.Notification
  alias Harness.Notification.Event
  alias Harness.Project
  alias Harness.ResultStore
  alias Harness.Run.LogRecord
  alias Harness.SettingsStore
  alias Harness.Worktree

  require Logger

  @audit_report_path ".harness/audit.json"
  @cold_check_score_d 3
  @cold_check_score_b 8
  @cold_check_score_u 5
  @cold_check_task_bundle "reviewer-pair"
  @cold_check_task_phase 20
  @cold_check_tail_limit 2_000
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
    # Thread the chosen auditor + its transcript out alongside the outcome (in
    # `meta`) so the dashboard ops feed (task 243) can relay both — the audit is
    # a real third-family agent run. Pre-worktree short-circuits carry empty meta.
    {outcome, meta} =
      with {:ok, repo} <- Project.local_repo_path(project),
           {:ok, target} <- target_branch(project),
           :ok <- fetch_origin(repo),
           {:ok, worktree} <- checkout(repo, target) do
        audit_in_worktree(worktree, repo, target, project, request)
      else
        short_circuit -> {short_circuit, %{}}
      end

    OpsFeed.broadcast(Op.audit_settled(project.name, meta[:agent], meta[:range], outcome, meta[:transcript]))
    outcome
  end

  @typep audit_meta :: %{
           optional(:agent) => String.t(),
           optional(:range) => String.t(),
           optional(:transcript) => binary()
         }

  @spec audit_in_worktree(Worktree.t(), String.t(), String.t(), Project.t(), request()) :: {outcome(), audit_meta()}
  defp audit_in_worktree(%Worktree{} = worktree, repo, target, project, request) do
    result =
      case unaudited_range(worktree.path, request.base_sha, project, target) do
        {:ok, :empty} ->
          {:noop, %{}}

        {:ok, range} ->
          run_auditor(worktree, repo, target, project, request, range)

        {:error, reason} ->
          {{:error, reason}, %{}}
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

  @spec run_auditor(Worktree.t(), String.t(), String.t(), Project.t(), request(), map()) :: {outcome(), audit_meta()}
  defp run_auditor(worktree, repo, target, project, request, range) do
    case select_auditor(request) do
      {:ok, auditor} ->
        agent = auditor_name(auditor)
        OpsFeed.broadcast(Op.audit_started(project.name, agent, range.log))
        finalize_audit(worktree, repo, target, project, request, range, auditor, agent)

      {:skipped, :no_audit_agent} = skip ->
        {skip, %{range: range.log}}
    end
  end

  # Drives the selected auditor and finalizes: ff-push whatever it committed and
  # record the watermark. Returns `{outcome, meta}` so `run/1` can relay the
  # agent + its raw transcript onto the ops feed.
  @spec finalize_audit(Worktree.t(), String.t(), String.t(), Project.t(), request(), map(), module(), String.t()) ::
          {outcome(), audit_meta()}
  defp finalize_audit(worktree, repo, target, project, request, range, auditor, agent) do
    case Driver.run(auditor, invocation(worktree, target, project, request, range, auditor_model(auditor)), []) do
      {:ok, %Outcome{output: output}} ->
        finalize_after_run(worktree, repo, target, project, request, range, agent, output)

      {:error, reason} ->
        {{:error, reason}, %{agent: agent, range: range.log}}
    end
  end

  @spec finalize_after_run(Worktree.t(), String.t(), String.t(), Project.t(), request(), map(), String.t(), binary()) ::
          {outcome(), audit_meta()}
  defp finalize_after_run(worktree, repo, target, project, request, range, agent, output) do
    meta = %{agent: agent, range: range.log, transcript: output}

    case head_sha(worktree.path) do
      {:ok, head} ->
        report = audit_report(worktree.path)
        log_audit_report(report)
        witness_cold_check(report, project, request_store(request), worktree.base_sha)
        outcome = push_if_advanced(repo, worktree, target, head)
        record_watermark(project, target, head, outcome)
        {outcome, meta}

      {:error, reason} ->
        {{:error, reason}, meta}
    end
  end

  # Display name for the chosen auditor adapter. A module the registry can't
  # reverse-map (test doubles via the explicit `:auditor` override) falls back to
  # its inspected module name — fact only, never a routing decision.
  @spec auditor_name(module()) :: String.t()
  defp auditor_name(module) do
    case AgentRegistry.agent_for_module(module) do
      {:ok, agent} -> to_string(agent)
      {:error, _reason} -> inspect(module)
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

  @spec invocation(Worktree.t(), String.t(), Project.t(), request(), map(), String.t() | nil) :: Invocation.t()
  defp invocation(worktree, target, project, request, range, model) do
    %Invocation{
      prompt: audit_prompt(target, project, range, rejection_history(project, request)),
      cwd: worktree.path,
      task_id: "audit-#{project.name}-#{range.short_sha}",
      model: model,
      permission_mode: :autonomous,
      adapter_opts: request[:auditor_opts] || [],
      env: Harness.RmapPath.ensure_agent_env(%{})
    }
  end

  @doc false
  # The auditor has no task-pin model axis (like the reviewer), so its model
  # resolves solely from the chosen auditor agent's `{:agent_model, agent}`
  # default. A module the registry can't reverse-map (test doubles via the
  # explicit `:auditor` override) yields nil — those doubles are model-incapable,
  # so `AgentAdapter.invoke/2` accepts nil; a model-capable real auditor with no
  # configured default is rejected there with `{:model_required, _}`, never run
  # on the CLI's ambient default. `@doc false` (not `defp`) so the resolution is
  # unit-testable, mirroring `select_auditor/1`.
  @spec auditor_model(module()) :: String.t() | nil
  def auditor_model(module) do
    case AgentRegistry.agent_for_module(module) do
      {:ok, agent} -> Config.agent_model(agent)
      {:error, _reason} -> nil
    end
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

  @spec rejection_line(LogRecord.t()) :: String.t()
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

    Discovery filing: when you notice follow-up work during this commit-range review — tech debt,
    an orphaned code path, an uncovered edge case, or a deferred decision — FILE it as a real rmap task
    via `rmap new --from-stdin --roadmap-path #{inspect(project.roadmap_path)}`. Provide a TOML
    `[[task]]` fragment. In `.audit/#{range.short_sha}.md`, name the filed task id(s). Do not leave TODO
    comments in source for audit follow-ups; the rmap task is the durable record.
    Harness does not decide what counts as a discovery; it does not score it, and reads nothing back — you decide
    whether to file and run the CLI yourself.

    Reviewer-quality feedback loop — recent reviewer rejections for this project (a cross-family
    reviewer is THE gate, and rejection is rare by design). If a task in the landed range above also
    appears here and the work that actually landed looks sound, that rejection may have been a FALSE
    rejection — note it in your `.audit/#{range.short_sha}.md` report. This only feeds the report; you
    still never revert or block.
    #{rejections}

    Project check hint (run yourself if needed; judge the output):
    #{project.check_command || "(none provided)"}

    Cold-build witness (required, post-merge fact, not a gate):
    This audit worktree is intentionally UN-warmed: no copied deps, _build, or PLTs. Run the project's
    clean-build/check command yourself in this cold tree using the project check hint above. Report the
    result in `#{@audit_report_path}` as `cold_check`: {"passed": true|false, "command": "<command you ran>",
    "tail": "<failing output tail, empty on pass>"}. Harness never runs this build itself and never reads
    an exit code; it only persists the fact you write. A red cold_check must not make you revert, unmerge,
    or block this already-landed merge.
    """
  end

  # Best-effort visibility: surface the agent's machine-readable summary in the
  # logs. A missing or malformed file is fine — the .audit/<sha>.md commit is
  # the durable report.
  @spec audit_report(String.t()) :: map()
  defp audit_report(worktree_path) do
    with {:ok, raw} <- Artifact.read(worktree_path, @audit_report_path),
         {:ok, report} when is_map(report) <- Jason.decode(raw) do
      report
    else
      _missing_or_malformed -> %{}
    end
  end

  @spec log_audit_report(map()) :: :ok
  defp log_audit_report(report) when map_size(report) > 0 do
    Logger.info("harness audit: #{inspect(report)}")

    :ok
  end

  defp log_audit_report(_report), do: :ok

  @spec request_store(request()) :: ResultStore.store()
  defp request_store(request), do: Map.get(request, :result_store, ResultStore.configured())

  @spec witness_cold_check(map(), Project.t(), ResultStore.store(), String.t()) :: :ok
  defp witness_cold_check(%{"cold_check" => cold_check}, project, store, landed_sha) when is_map(cold_check) do
    persist_cold_check(project, store, landed_sha, cold_check)

    if cold_check_failed?(cold_check) do
      reason = cold_check_reason(landed_sha, cold_check)
      task_id = file_blocked_cold_check_task(project, landed_sha, cold_check, reason)
      notify_cold_check_red(project, task_id, reason)
    end

    :ok
  end

  defp witness_cold_check(_report, _project, _store, _landed_sha), do: :ok

  @spec persist_cold_check(Project.t(), ResultStore.store(), String.t(), map()) :: :ok
  defp persist_cold_check(project, store, landed_sha, cold_check) do
    case ResultStore.list_run_records(store, project_name: project.name, include_transcripts: true) do
      {:ok, records} -> persist_matching_cold_check(records, store, landed_sha, cold_check)
      {:error, reason} -> log_cold_check_persist_failure(project, landed_sha, reason)
    end
  end

  @spec persist_matching_cold_check([LogRecord.t()], ResultStore.store(), String.t(), map()) :: :ok
  defp persist_matching_cold_check(records, store, landed_sha, cold_check) do
    case Enum.find(records, &(&1.landed_sha == landed_sha)) do
      %LogRecord{} = record -> record_cold_check(record, store, cold_check)
      nil -> :ok
    end
  end

  @spec record_cold_check(LogRecord.t(), ResultStore.store(), map()) :: :ok
  defp record_cold_check(record, store, cold_check) do
    record = %{record | cold_check: cold_check, approved_then_found_red: approved_then_found_red(record, cold_check)}

    case ResultStore.record_run(record, store) do
      :ok -> :ok
      {:error, reason} -> log_cold_check_persist_failure(record.project_name, record.landed_sha, reason)
    end
  end

  @spec approved_then_found_red(LogRecord.t(), map()) :: map()
  defp approved_then_found_red(record, cold_check) do
    if cold_check_failed?(cold_check) and Map.get(record, :verdict) == :approve do
      %{
        "reviewer_adapter" => module_name(record.reviewer_adapter),
        "reviewer_agent" => reviewer_agent(record.reviewer_adapter),
        "reviewer_model" => record.reviewer_model,
        "review_facets" => record.review_facets || %{},
        "domains" => stringify_domains(record.domains),
        "cold_check" => cold_check
      }
    else
      record.approved_then_found_red || %{}
    end
  end

  @spec module_name(module() | nil) :: String.t() | nil
  defp module_name(nil), do: nil
  defp module_name(module) when is_atom(module), do: Atom.to_string(module)

  @spec reviewer_agent(module() | nil) :: String.t() | nil
  defp reviewer_agent(nil), do: nil

  defp reviewer_agent(module) when is_atom(module) do
    case AgentRegistry.agent_for_module(module) do
      {:ok, agent} -> Atom.to_string(agent)
      {:error, _reason} -> nil
    end
  end

  @spec stringify_domains(term()) :: [String.t()]
  defp stringify_domains(domains) when is_list(domains), do: Enum.map(domains, &to_string/1)
  defp stringify_domains(_domains), do: []

  @spec log_cold_check_persist_failure(Project.t() | String.t() | nil, String.t() | nil, term()) :: :ok
  defp log_cold_check_persist_failure(project, landed_sha, reason) do
    Logger.warning(
      "harness audit: failed to persist cold_check fact for #{inspect(project)} landed #{landed_sha}: #{inspect(reason)}"
    )

    :ok
  end

  @spec cold_check_failed?(map()) :: boolean()
  defp cold_check_failed?(%{"passed" => false}), do: true
  defp cold_check_failed?(%{passed: false}), do: true
  defp cold_check_failed?(_cold_check), do: false

  @spec cold_check_reason(String.t(), map()) :: String.t()
  defp cold_check_reason(landed_sha, cold_check) do
    "post-merge cold check red for landed SHA #{landed_sha}: #{cold_check_tail(cold_check)}"
  end

  @spec cold_check_tail(map()) :: String.t()
  defp cold_check_tail(cold_check) do
    cold_check
    |> Map.get("tail", Map.get(cold_check, :tail, "(no failing output tail reported)"))
    |> to_string()
    |> String.slice(0, @cold_check_tail_limit)
  end

  @spec file_blocked_cold_check_task(Project.t(), String.t(), map(), String.t()) :: String.t()
  defp file_blocked_cold_check_task(project, landed_sha, cold_check, reason) do
    with {:ok, output} <- rmap_new(project, cold_check_task_fragment(landed_sha, cold_check)),
         {:ok, task_id} <- parse_created_task_id(output),
         {:ok, _blocked} <- rmap_status_blocked(project, task_id, reason) do
      task_id
    else
      failure ->
        Logger.warning("harness audit: failed to file blocked cold-check task: #{inspect(failure)}")
        "cold-check"
    end
  end

  @spec cold_check_task_fragment(String.t(), map()) :: String.t()
  defp cold_check_task_fragment(landed_sha, cold_check) do
    title = "Fix post-merge cold-check red for #{short_sha(landed_sha)}"

    body =
      "The post-merge audit AI reported a red cold check for landed SHA #{landed_sha}.\n\n#{cold_check_tail(cold_check)}"

    """
    [[task]]
    phase = #{@cold_check_task_phase}
    bundle = #{Jason.encode!(@cold_check_task_bundle)}
    title = #{Jason.encode!(title)}
    scores = { d = #{@cold_check_score_d}, b = #{@cold_check_score_b}, u = #{@cold_check_score_u} }
    markers = ["bug"]
    body = #{Jason.encode!(body)}
    acceptance_criteria = [#{Jason.encode!("The clean-build/check passes from a cold checkout at landed SHA #{landed_sha}.")}]
    out_of_scope = ["Reverting or unmerging the already-landed SHA"]
    """
  end

  @spec rmap_new(Project.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp rmap_new(project, fragment) do
    run_rmap_with_input(tasks_path(project), fragment)
  end

  @spec rmap_status_blocked(Project.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp rmap_status_blocked(project, task_id, reason) do
    run_rmap(["status", task_id, "blocked", "--reason", reason, "--tasks-path", tasks_path(project)], [])
  end

  @spec run_rmap([String.t()], keyword()) :: {:ok, String.t()} | {:error, term()}
  # System.cmd/3 with an argv list spawns directly — no shell, no interpolation.
  # sobelow_skip ["CI.System"]
  defp run_rmap(args, opts) do
    case System.cmd("rmap", args, Keyword.merge([stderr_to_stdout: true], opts)) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {status, output, args}}
    end
  rescue
    e in ErlangError -> {:error, e}
  end

  @spec run_rmap_with_input(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  # The shell is used only for piping stdin; the task path is passed as argv.
  # sobelow_skip ["CI.System"]
  defp run_rmap_with_input(tasks_path, fragment) do
    args = [
      "-c",
      ~S"""
      printf '%s' "$HARNESS_RMAP_FRAGMENT" | rmap new --from-stdin --tasks-path "$1"
      """,
      "harness-audit",
      tasks_path
    ]

    case System.cmd("/bin/sh", args, stderr_to_stdout: true, env: [{"HARNESS_RMAP_FRAGMENT", fragment}]) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {status, output, args}}
    end
  rescue
    e in ErlangError -> {:error, e}
  end

  @spec parse_created_task_id(String.t()) :: {:ok, String.t()} | {:error, :created_task_id_missing}
  defp parse_created_task_id(output) do
    case Regex.run(~r/created task ([^\s]+)/, output) do
      [_match, id] -> {:ok, id}
      _other -> {:error, :created_task_id_missing}
    end
  end

  @spec tasks_path(Project.t()) :: String.t()
  defp tasks_path(%Project{roadmap_path: path}) do
    if Path.basename(path) == "tasks.toml", do: path, else: Path.join([path, "roadmap", "tasks.toml"])
  end

  @spec short_sha(String.t()) :: String.t()
  defp short_sha(sha) when is_binary(sha), do: String.slice(sha, 0, 7)

  @spec notify_cold_check_red(Project.t(), String.t(), String.t()) :: :ok
  defp notify_cold_check_red(project, task_id, reason) do
    Notification.notify(%Event{
      type: :blocked,
      task_id: task_id,
      project: project.name,
      outcome: reason
    })
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

      case write_watermarks(record) do
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
    if watermark_persistence_enabled?() do
      SettingsStore.fetch(:audit)
    else
      :not_found
    end
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

  @spec write_watermarks(map()) :: :ok | {:error, term()}
  defp write_watermarks(record), do: SettingsStore.put(:audit, record)

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
