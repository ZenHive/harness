defmodule Harness.Run.Actions.Reviewing do
  @moduledoc false

  import Harness.Run.Actions.Control, only: [cancel_task: 1, clear_operator_steer: 1, terminate_reviewer: 1]
  import Harness.Run.Actions.Discernment, only: [format_acceptance_criteria: 1, task_text: 1]
  import Harness.Run.Actions.Timeouts, only: [reviewer_idle_timeout: 1]
  import Harness.Run.Actions.Transcript, only: [stamp_state_entry: 2]

  import Harness.Run.Actions.Worktree,
    only: [
      agent_rule_content: 1,
      commit_worktree: 3,
      current_sha: 1,
      in_run_env: 1,
      put_opt: 3,
      run_driver: 4,
      worktree_isolation_limitation: 1
    ]

  alias Harness.Agent.Settings, as: AgentSettings
  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Outcome
  alias Harness.AgentKPI
  alias Harness.AgentRegistry
  alias Harness.Config
  alias Harness.Git
  alias Harness.ModelAvailability
  alias Harness.ResultStore
  alias Harness.Run.Review
  alias Harness.Text
  alias Harness.Worktree
  alias Harness.Worktree.Isolation

  require Logger

  @reviewer_rejection_sample 500
  @reviewer_reprompt_limit 1
  @reviewer_transcript_tail_bytes 40_000

  @type data :: map()
  @type handler_result :: term()
  # Reviewer spawn/idle timeout fallback (plan gap 6). Before settling the run
  # :failed, rotate to the next eligible cross-family reviewer carved at
  # route-into-review (`reviewer_candidates`, cross-family by construction). The
  # candidate list is finite, so rotation is bounded by construction; the count
  # is witnessed as a raw fact on the run record. This is MECHANICAL — picking the
  # next candidate, no content inspection to judge whether the work is
  # recoverable — the same class as the missing/malformed re-prompt. Exhausting
  # the candidates settles :review_stuck exactly as before.
  @doc false
  @spec rotate_or_fail_review(data(), String.t()) :: handler_result()
  def rotate_or_fail_review(%{reviewer_candidates: [next | rest]} = data, _report) do
    # Terminate the timed-out reviewer (SIGKILL via its captured os_pid) and tear
    # down its step task BEFORE re-entering :reviewing — same ordering as
    # fail_review_stuck so closing the Port can't race the pid (Task 199 audit).
    terminate_reviewer(data)
    cancel_task(data.task)

    Logger.info(
      "harness run: reviewer timed out for #{data.run_id} — rotating to #{inspect(next)} " <>
        "(rotation #{data.reviewer_rotation_count + 1})"
    )

    data = %{
      data
      | task: nil,
        reviewer_run: nil,
        reviewer_adapter: next,
        reviewer_candidates: rest,
        reviewer_rotation_count: data.reviewer_rotation_count + 1
    }

    # :repeat_state re-runs the :reviewing enter callback, spawning the rotated-to
    # reviewer in the same worktree and re-arming the spawn/idle watchdogs.
    {:repeat_state, data}
  end

  def rotate_or_fail_review(data, report), do: fail_review_stuck(data, report)

  @doc false
  @spec fail_review_stuck(data(), String.t()) :: handler_result()
  def fail_review_stuck(data, report) do
    # Terminate the reviewer (SIGKILL via its captured os_pid) BEFORE tearing
    # down the task that owns its Port — closing the port first could reap/race
    # the pid (Task 199 audit).
    terminate_reviewer(data)
    cancel_task(data.task)
    {:next_state, :failed, clear_reviewer_run(%{data | task: nil, reason: {:review_stuck, report}})}
  end

  @doc false
  @spec clear_reviewer_run(data()) :: data()
  def clear_reviewer_run(data), do: %{data | reviewer_run: nil}

  # ── The gate: routing into review and settling on the verdict artifact ───

  # Every committed worktree goes to the reviewer — THE gate. There is no
  # mechanical verification step; the reviewer runs the project's checks itself
  # and writes the verdict artifact harness reads. A run with no available
  # cross-family reviewer cannot be gated, so it fails (the task goes back to
  # the queue for re-dispatch when one is available).
  @doc false
  @spec route_to_review(data()) :: handler_result()
  def route_to_review(data) do
    case select_reviewers(data) do
      {:ok, [primary | candidates]} ->
        # Capture the implementer's final SHA ONCE, here at the single entry into
        # review. `measure_reviewer_diff/2` spans from this baseline, so a
        # Task-203 re-prompt OR a timeout rotation (both `:repeat_state`, which
        # never re-routes) keeps the original baseline and the fix-diff KPI counts
        # the WHOLE review — including a first pass that fixed-then-exited before
        # its verdict. `candidates` is the ordered cross-family fallback set the
        # reviewer-timeout rotation (`rotate_or_fail_review/2`) draws from.
        {:next_state, :reviewing,
         %{
           data
           | reviewer_adapter: primary,
             reviewer_candidates: candidates,
             reviewer_pre_review_sha: current_sha(data)
         }}

      {:error, reason} ->
        report = "No cross-family reviewer adapter available: #{inspect(reason)}"
        {:next_state, :failed, %{data | reason: {:review_stuck, report}}}
    end
  end

  @doc false
  @spec route_after_dispatch(data()) :: handler_result()
  def route_after_dispatch(%{review_only?: true} = data) do
    diff_size = data.review_only_agent_diff_size || 0

    data
    |> Map.put(:agent_diff_size, diff_size)
    |> Map.put(:implementer_empty_diff?, diff_size == 0)
    |> route_to_review()
  end

  def route_after_dispatch(data), do: {:next_state, :running, data}

  @doc false
  @spec maybe_validate_implementer_isolation(data()) ::
          :ok | {:error, {:worktree_isolation_unsupported, module(), String.t()}}
  def maybe_validate_implementer_isolation(%{review_only?: true}), do: :ok

  def maybe_validate_implementer_isolation(data) do
    Isolation.validate(
      data.adapter,
      AgentAdapter.supports?(data.adapter, :worktree_isolation),
      worktree_isolation_limitation(data.adapter)
    )
  end

  # The verdict artifact is read mechanically — approve settles :done, reject
  # settles :failed with the reviewer's report, an unreadable artifact settles
  # :failed as review_stuck. What the work MEANS was the reviewer's judgment;
  # this function only routes on what it wrote.
  @doc false
  @spec settle_review(data(), {:ok, Review.t()} | {:error, Review.error()}) :: handler_result()
  def settle_review(data, {:ok, %Review{verdict: :approve} = review}) do
    {:next_state, :done, clear_operator_steer(%{data | review: review, reason: :approved})}
  end

  def settle_review(data, {:ok, %Review{verdict: :reject} = review}) do
    {:next_state, :failed, %{data | review: review, reason: {:review_rejected, review.report}}}
  end

  # Unreadable verdict — the recoverable case (Task 203, generalized to cover a
  # MALFORMED artifact alongside a MISSING one). On the FIRST miss only, re-enter
  # :reviewing to re-invoke the same reviewer in the same worktree with a terse
  # nudge (see `reviewer_reprompt/1`); `:repeat_state` re-runs the enter callback,
  # re-arming the spawn/idle watchdogs identically to the first pass. The clause
  # matches ANY `{:error, _}` read result — harness inspects no content to judge
  # whether the verdict is recoverable; it simply re-issues the mandatory write
  # once. A second miss (count already at the limit) falls through to the honest
  # :review_stuck failure below — no loop.
  def settle_review(%{reviewer_reprompt_count: count} = data, {:error, reason}) when count < @reviewer_reprompt_limit do
    Logger.info(
      "harness run: reviewer verdict unreadable (#{inspect(reason)}) for #{data.run_id} — " <>
        "re-prompting once (attempt #{count + 1})"
    )

    {:repeat_state, %{stamp_state_entry(:recovery_review, data) | reviewer_reprompt_count: count + 1, task: nil}}
  end

  def settle_review(data, {:error, :missing}) do
    report = "Reviewer wrote no #{Review.artifact_path()} verdict artifact."
    {:next_state, :failed, %{data | reason: {:review_stuck, report}}}
  end

  def settle_review(data, {:error, {:malformed, detail}}) do
    report = "Reviewer verdict artifact is malformed: #{inspect(detail)}"
    {:next_state, :failed, %{data | reason: {:review_stuck, report}}}
  end

  # Resolves the ordered cross-family reviewer set for a run. The head is the
  # primary reviewer; the tail is the rotation fallback the reviewer-timeout
  # path (`rotate_or_fail_review/2`) draws from. Auto-selection returns the whole
  # prioritized registry slate; an explicit pin returns a one-element list; an
  # explicit list is an operator-supplied rotation order (each element validated
  # cross-family + dispatchable). Empty ⇒ `:review_stuck`.
  @doc false
  @spec select_reviewers(data()) :: {:ok, [module(), ...]} | {:error, term()}
  def select_reviewers(%{reviewer: nil} = data) do
    case auto_reviewer_modules(data) do
      [] -> {:error, {:no_cross_family_reviewer, data.item.agent}}
      modules -> {:ok, modules}
    end
  end

  def select_reviewers(%{reviewer: reviewers} = data) when is_list(reviewers) do
    resolve_reviewer_list(data, reviewers)
  end

  def select_reviewers(%{reviewer: reviewer} = data) do
    with {:ok, module} <- resolve_single_reviewer(data, reviewer), do: {:ok, [module]}
  end

  # The full prioritized cross-family slate from the registry — every installed,
  # reviewer-eligible agent that is not the implementer's family, ordered by
  # soft availability and historical rejection rate. The list is the rotation
  # order on a reviewer timeout, not just the single auto-pick.
  @doc false
  @spec auto_reviewer_modules(data()) :: [module()]
  def auto_reviewer_modules(data) do
    implementer = data.item.agent

    AgentRegistry.agents()
    |> Enum.reject(fn {agent, _module} -> agent == implementer end)
    |> Enum.filter(fn {_agent, module} -> reviewer_dispatchable?(module) end)
    |> prioritize_reviewers(reviewer_rejection_rates())
    |> Enum.map(fn {_agent, module} -> module end)
  end

  # An explicit reviewer rotation order: resolve + validate each in turn, failing
  # fast on the first invalid pin (mirrors the single-explicit refusal semantics).
  @doc false
  @spec resolve_reviewer_list(data(), [atom() | module()]) :: {:ok, [module(), ...]} | {:error, term()}
  def resolve_reviewer_list(data, reviewers) do
    reviewers
    |> Enum.reduce_while([], fn reviewer, acc ->
      case resolve_single_reviewer(data, reviewer) do
        {:ok, module} -> {:cont, [module | acc]}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      [] -> {:error, {:no_cross_family_reviewer, data.item.agent}}
      modules -> {:ok, Enum.reverse(modules)}
    end
  end

  @doc false
  @spec resolve_single_reviewer(data(), atom() | module()) :: {:ok, module()} | {:error, term()}
  def resolve_single_reviewer(data, reviewer) do
    with {:ok, module} <- resolve_reviewer(reviewer),
         :ok <- ensure_cross_family_reviewer(data.item.agent, module),
         true <- explicit_reviewer_dispatchable?(module) || {:error, {:reviewer_unavailable, module}} do
      {:ok, module}
    end
  end

  # Orders cross-family reviewer candidates, deprioritizing transiently
  # unavailable adapters and high rejection rates. A stable sort by availability
  # AS A SOFT HINT and each candidate's historical rejection rate AS a reviewer
  # (`rates`, keyed by adapter module): a busy reviewer sinks below an available
  # one, and a reviewer that rejects too freely sinks among equally available
  # peers. Advisory only — it reorders, never removes (no blacklist).
  # `@doc false` public so the routing decision is unit-testable without a real
  # auto-selection run (which needs installed agent CLIs).
  @doc false
  @spec prioritize_reviewers([{atom(), module()}], %{optional(module()) => float()}) :: [{atom(), module()}]
  def prioritize_reviewers(candidates, rates) when is_list(candidates) and is_map(rates) do
    Enum.sort_by(candidates, fn {_agent, module} -> {availability_rank(module), Map.get(rates, module, 0.0)} end)
  end

  # Advisory cross-family tiebreaker: among equally-dispatchable reviewers,
  # prefer the one with the lower historical rejection rate AS a reviewer, so a
  # reviewer that rejects too freely is deprioritized (never blacklisted —
  # unmeasured reviewers default to 0.0 and the stable sort preserves registry
  # order when there is no data). Best-effort: a disabled/erroring store yields
  # an empty map and the original registry order stands.
  @doc false
  @spec reviewer_rejection_rates() :: %{optional(module()) => float()}
  def reviewer_rejection_rates do
    case ResultStore.list_run_records(limit: @reviewer_rejection_sample) do
      {:ok, records} ->
        records
        |> AgentKPI.aggregate_reviewer_rejections()
        |> Map.new(fn {module, metrics} -> {module, metrics.rejection_rate} end)

      _error ->
        %{}
    end
  end

  @doc false
  @spec resolve_reviewer(atom() | module()) :: {:ok, module()} | {:error, term()}
  def resolve_reviewer(reviewer) when is_atom(reviewer) do
    case AgentRegistry.module_for_agent(reviewer) do
      {:ok, module} ->
        {:ok, module}

      {:error, _reason} ->
        if Code.ensure_loaded?(reviewer) and function_exported?(reviewer, :build_command, 1) do
          {:ok, reviewer}
        else
          {:error, {:unknown_reviewer, reviewer}}
        end
    end
  end

  @doc false
  @spec ensure_cross_family_reviewer(atom(), module()) :: :ok | {:error, term()}
  def ensure_cross_family_reviewer(implementer, reviewer_module) do
    case AgentRegistry.agent_for_module(reviewer_module) do
      {:ok, ^implementer} -> {:error, {:same_family_reviewer, implementer, reviewer_module}}
      _other -> :ok
    end
  end

  @doc false
  @spec availability_rank(module()) :: 0 | 1
  def availability_rank(module), do: if(AgentRegistry.available?(module), do: 0, else: 1)

  # Reviewer-dispatchability is governed by installed? and reviewer_eligible?.
  # The implementer-level AgentSettings.enabled? flag is deliberately NOT a
  # reviewer gate. The two roles are orthogonal: `enabled?` answers "may this
  # agent IMPLEMENT?", `reviewer_eligible?` answers "may it REVIEW?". Coupling
  # them made "reviewer-only" (disabled implementer + eligible reviewer)
  # unexpressable — a Claude pinned as the dedicated reviewer but disabled as an
  # implementer was rejected as {:reviewer_unavailable, Claude}, settling every
  # run :review_stuck. To bar an agent from BOTH roles, turn off both flags.
  #
  # AgentRegistry.available?/1 is also deliberately NOT a reviewer gate. Its
  # moduledoc defines availability as a restart-cleared soft latency hint, so it
  # belongs in prioritize_reviewers/2 ordering only. Treating it as a hard
  # eligibility filter can empty the whole cross-family slate and discard
  # completed implementer work before any reviewer is tried.
  @doc false
  @spec reviewer_dispatchable?(module()) :: boolean()
  def reviewer_dispatchable?(module) do
    AgentRegistry.installed?(module) and
      reviewer_eligible?(module)
  end

  # Reviewer-eligibility gate, distinct from the implementer-level
  # AgentSettings.enabled? flag: an ineligible agent may still implement, it just
  # can't be picked (auto or explicit) as THE gate; conversely a disabled
  # implementer that is reviewer-eligible CAN still be the gate (reviewer-only).
  # Operator-set and persisted via AgentSettings (Task 182), seeded from its
  # in-code default ([:pi]) on first boot — Pi/OSS models aren't yet trusted to
  # run the checks + write a sound verdict (Task 181). Unknown module ⇒ eligible
  # (default-allow).
  @doc false
  @spec reviewer_eligible?(module()) :: boolean()
  def reviewer_eligible?(module) do
    case AgentRegistry.agent_for_module(module) do
      {:ok, agent} -> AgentSettings.reviewer_eligible?(agent)
      {:error, _reason} -> true
    end
  end

  @doc false
  @spec explicit_reviewer_dispatchable?(module()) :: boolean()
  def explicit_reviewer_dispatchable?(module) do
    case AgentRegistry.agent_for_module(module) do
      {:ok, _agent} -> reviewer_dispatchable?(module)
      {:error, _reason} -> AgentRegistry.available?(module)
    end
  end

  # Runs the reviewer agent in the implementer's worktree, commits whatever it
  # changed (its own fixes), measures the reviewer's own diff, and reads the
  # verdict artifact. The artifact read result rides inside the :ok tuple so a
  # missing/malformed verdict still carries the outcome + diff evidence back to
  # the gen_statem instead of discarding it.
  @doc false
  @spec run_reviewer(data(), pid()) ::
          {:ok,
           %{
             outcome: Outcome.t(),
             reviewer_diff_size: non_neg_integer(),
             review: {:ok, Review.t()} | {:error, Review.error()}
           }}
          | {:error, term()}
  def run_reviewer(data, parent) do
    # Set once at the single route-into-review entry (`route_to_review/1`) so the
    # fix-diff spans the whole review across any Task-203 re-prompt; `||` only
    # guards the degenerate nil (a run that reached review without routing).
    pre_review_sha = data.reviewer_pre_review_sha || current_sha(data)

    with {:ok, %Outcome{} = outcome} <-
           run_driver(data, data.reviewer_adapter, reviewer_invocation(data), reviewer_driver_opts(data, parent)),
         {:ok, _status, _total_diff_size} <- commit_worktree(data, data.worktree, reviewer_commit_message(data)) do
      {:ok,
       %{
         outcome: outcome,
         reviewer_diff_size: measure_reviewer_diff(data, pre_review_sha),
         review: Review.read(data.worktree.path)
       }}
    end
  end

  # Changed-line count of the reviewer's own commits — the "how much fixing was
  # needed" KPI signal. Zero means the implementer's work needed no fixes.
  # Measurement failures degrade to 0 rather than failing the run: the verdict
  # artifact, not this number, is the gate.
  @doc false
  @spec measure_reviewer_diff(data(), String.t()) :: non_neg_integer()
  def measure_reviewer_diff(data, pre_review_sha) do
    case Worktree.diff_size_since(data.worktree, pre_review_sha) do
      {:ok, diff_size} ->
        diff_size

      {:error, reason} ->
        Logger.warning("harness run: reviewer diff measurement failed for #{data.run_id}: #{inspect(reason)}")
        0
    end
  end

  @doc false
  @spec reviewer_invocation(data()) :: Invocation.t()
  def reviewer_invocation(data) do
    %Invocation{
      prompt: reviewer_invocation_prompt(data),
      cwd: data.worktree.path,
      log_tag: "#{data.item.id}-review",
      model: reviewer_model(data),
      rule_content: agent_rule_content(data.project),
      permission_mode: :autonomous,
      adapter_opts: data.reviewer_adapter_opts,
      env: in_run_env(data)
    }
  end

  # The reviewer has no task-pin model axis (the task's `model` pins only the
  # implementer), so it resolves from the selected reviewer adapter's agent:
  # reviewer override > shared per-agent default. A nil result for a model-capable
  # reviewer is rejected by ensure_reviewer_model_available/1, never silently
  # passed to the reviewer CLI as its ambient default.
  @doc false
  @spec reviewer_model(data()) :: String.t() | nil
  def reviewer_model(%{reviewer_adapter: reviewer_adapter, reviewer_agent_resolver: resolver})
      when is_atom(reviewer_adapter) and not is_nil(reviewer_adapter) and is_function(resolver, 1) do
    case resolver.(reviewer_adapter) do
      {:ok, agent} -> Config.reviewer_model(agent)
      {:error, _reason} -> nil
    end
  end

  def reviewer_model(_data), do: nil

  @doc false
  @spec reviewer_model_available?(data()) :: :ok | {:error, term()}
  def reviewer_model_available?(%{reviewer_adapter: reviewer_adapter} = data) when is_atom(reviewer_adapter) do
    ensure_reviewer_model_available(data)
  end

  @doc false
  @spec ensure_reviewer_model_available(data()) :: :ok | {:error, term()}
  def ensure_reviewer_model_available(%{reviewer_adapter: reviewer_adapter, reviewer_agent_resolver: resolver})
      when is_atom(reviewer_adapter) and is_function(resolver, 1) do
    case resolver.(reviewer_adapter) do
      {:ok, agent} -> check_reviewer_model(reviewer_adapter, agent)
      {:error, _} -> :ok
    end
  end

  def ensure_reviewer_model_available(%{reviewer_adapter: reviewer_adapter}) do
    case AgentRegistry.agent_for_module(reviewer_adapter) do
      {:ok, agent} -> check_reviewer_model(reviewer_adapter, agent)
      {:error, _} -> :ok
    end
  end

  # The reviewer is the most exposed model-less path — it has no task-pin axis,
  # so a model-capable reviewer adapter with no configured reviewer/agent model
  # is rejected before the reviewer is dispatched, never silently using the
  # reviewer CLI's ambient default.
  @doc false
  @spec check_reviewer_model(module(), atom()) :: :ok | {:error, term()}
  def check_reviewer_model(reviewer_adapter, agent) do
    model = Config.reviewer_model(agent)

    cond do
      is_nil(model) and AgentAdapter.requires_model?(reviewer_adapter) ->
        {:error, {:model_required, agent}}

      ModelAvailability.available?(agent, model) ->
        :ok

      true ->
        {:error, {:unavailable, agent, model, available: ModelAvailability.list_available_ids(agent)}}
    end
  end

  @doc false
  @spec maybe_capture_structured_failure(data()) :: :ok
  def maybe_capture_structured_failure(%{adapter: adapter, reason: reason} = data) when is_atom(adapter) do
    case ModelAvailability.structured_quota_signal(reason) do
      {:ok, _seconds, _model} ->
        :ok = AgentRegistry.mark_unavailable(adapter, reason, model: data.requested_model)

      :error ->
        :ok
    end
  end

  @doc false
  @spec reviewer_driver_opts(data(), pid()) :: keyword()
  def reviewer_driver_opts(data, parent) do
    [
      on_spawn: fn run -> send(parent, {:reviewer_handle, run}) end,
      on_output: fn chunk -> send(parent, {:transcript_chunk, chunk}) end
    ]
    |> put_opt(:total_timeout, data.total_timeout)
    |> put_opt(:idle_timeout, reviewer_idle_timeout(data.idle_timeout))
    |> put_opt(:progress_timeout, data.progress_timeout)
  end

  # First pass gets the full gate prompt; a Task-203 re-prompt (count > 0) gets
  # the terse "harness couldn't read your verdict — write a valid one now" nudge.
  @doc false
  @spec reviewer_invocation_prompt(data()) :: String.t()
  def reviewer_invocation_prompt(%{reviewer_reprompt_count: count} = data) when count > 0, do: reviewer_reprompt(data)

  def reviewer_invocation_prompt(data), do: reviewer_prompt(data)

  # Task 203 re-prompt (generalized): a fresh invocation of the same reviewer
  # whose prior pass left no READABLE verdict — it either exited without writing
  # the artifact or wrote invalid JSON. All review work is already committed in
  # this worktree; the ONE remaining job is producing a valid artifact. Terse by
  # design — the verdict schema + the task framing the agent needs to ground an
  # honest approve/reject, nothing more.
  @doc false
  @spec reviewer_reprompt(data()) :: String.t()
  def reviewer_reprompt(data) do
    """
    You are the cross-family reviewer for a harness run. You already reviewed this work in a prior
    pass, but harness could not read a valid verdict from `#{Review.artifact_path()}` — it was missing
    or contained invalid JSON, so harness is about to discard the entire run.

    This is your ONLY remaining job, nothing else: all prior fixes are already committed in this
    worktree — assess its current state, run the project's checks below, then write a VALID verdict
    file NOW and stop. Do not re-do a full review or make new changes unless a check is actually
    failing.

    You MUST run the project's checks. If checks are still red after your fixes and you choose to
    dismiss that red as environmental or out-of-scope, first reproduce the benign cause and record
    that reproduced cause in `checks` and `concerns` (command, failing output, and mechanism). If you
    cannot reproduce a benign cause, treat the red as a real defect.

    Verdict artifact — write this, then stop:

    #{Review.artifact_path()}
    {
      "verdict": "approve" | "reject",
      "report": "<what you found, what you fixed, why you decided>",
      "checks": {"<command you ran>": {"passed": true | false, "output": "<short relevant output>", "mechanism": "<why a red is benign, if dismissed>"}},
      "concerns": [],
      "facets": {"language": "...", "surface": "...", "archetype": "...", "difficulty": "...", "risk": "..."},
      "skills": {"<domain or quality the diff exercised>": {"score": <0-10>, "note": "<one line>"}}
    }

    `checks` records the actual command(s) you ran and your own boolean pass/fail call for each.
    `concerns` is a list of caveats you are explicitly approving with; leave it [] only when there
    are none. A dismissed red is never a bare prose aside.

    `facets` characterizes what this task ACTUALLY was, read from the spec + the real diff (open
    vocabulary). `skills` scores ONLY the domains and qualities the diff genuinely exercised (otp,
    ecto, concurrency, error_handling, idiom, test_rigor, security, docs, truthfulness, ...) — each a
    {"score": 0-10, "note": "..."} map, open vocabulary, no padding with zeros.

    Fixing is cheaper than rejecting — approve anything salvageable; reject only if nothing is.
    A missing or malformed #{Review.artifact_path()} fails this run for good.

    Project check hint (run these yourself; judge the output):
    #{Text.placeholder(data.project.check_command)}

    Implementer: #{data.item.agent}
    Current commit: #{current_sha(data)}

    Task spec:
    #{Text.placeholder(task_text(data))}

    Acceptance criteria:
    #{format_acceptance_criteria(data.item.acceptance_criteria)}
    """
  end

  # The reviewer's instructions — THE gate's prompt. The judgment (is the work
  # good, do the checks pass in a way that matters, what does an empty diff
  # mean) lives entirely in the reviewer agent; harness only frames it and
  # reads the artifact it writes.
  @doc false
  @spec reviewer_prompt(data()) :: String.t()
  def reviewer_prompt(data) do
    """
    You are the cross-family reviewer for a harness run — THE gate that decides whether this work is accepted.

    #{reviewer_situation(data)}

    Your job, in order:
    1. Review the work against the task spec and acceptance criteria below.
    2. You MUST run the project's checks yourself (hint below) and judge the results.
    3. Fix everything that needs fixing — your own edits, your own commits. Wrong approach, bugs,
       missing tests, failing checks, style: fix it all, then approve.
    4. LAST, after every fix and check is done: write your verdict to `#{Review.artifact_path()}`
       (format below). This is your FINAL action — write the file, then stop.

    If checks are still red after your fixes and you choose to dismiss that red as environmental or
    out-of-scope, first reproduce the benign cause and record that reproduced cause in `checks` and
    `concerns` (command, failing output, and mechanism). If you cannot reproduce a benign cause,
    treat the red as a real defect. A dismissed red is never a bare prose aside.

    ⚠️ Writing `#{Review.artifact_path()}` is mandatory and unconditional — it is the ONE thing
    harness reads. If you finish fixing and reviewing but exit WITHOUT writing it, your entire run is
    discarded as a failure and the work is thrown away, no matter how much you fixed. Do not end your
    turn, declare yourself done, or go idle until the file is written. Even when you reject, even when
    you ran out of other things to do — the verdict file is always the last thing you write before you
    stop. Prose in your transcript has no effect; only this file does.

    Fixing is always cheaper than rejecting — a rejection costs two more full agent runs.
    Anything you can fix: fix it and approve. Reject ONLY if there is literally nothing to salvage
    (an empty or unusable worktree, or work so destructive or off-task that redoing it from scratch
    is faster than fixing it).

    Never edit `roadmap/tasks.toml`, `roadmap/data.json`, `ROADMAP.md`, or `CHANGELOG.md` in this
    worktree. Do not mark the current task done, verified, shipped, pending, or blocked — harness
    writes the outcome back (`done` + `verified` + `shipped_in`) after you approve and the work lands.
    If the implementer left one of those files edited, revert it as part of your fixes — it is not
    deliverable.

    Discovery proposals: if you surface genuine follow-up work while gating and choose NOT to fix it
    inline, put a structured proposal in `proposed_tasks` in the verdict artifact. You decide what
    counts as a discovery; harness preserves the proposals but does not classify, rank, dedupe, merge,
    or file them. After the run lands, the orchestrator evaluates the proposals against the live
    pending set and files any warranted task through its own task-writing gate.

    Verdict artifact — REQUIRED final action, write it even when you reject:

    #{Review.artifact_path()}
    {
      "verdict": "approve" | "reject",
      "report": "<what you found, what you fixed, why you decided>",
      "checks": {
        "<command you ran>": {
          "passed": true | false,
          "output": "<short relevant output>",
          "mechanism": "<why a red is benign, if dismissed>"
        }
      },
      "concerns": [],
      "proposed_tasks": [
        {
          "title": "<short task title>",
          "body": "<what to accomplish and success criteria>",
          "suggested_scores": {"difficulty": 1-10, "benefit": 1-10, "urgency": 1-10},
          "suggested_markers": ["parallel"],
          "evidence": "<what in this review revealed the follow-up>"
        }
      ],
      "facets": {
        "language": "<elixir | rust | js | ...>",
        "surface": "<otp | ecto | phoenix | liveview | cli | migration | docs | ...>",
        "archetype": "<feature | bugfix | refactor | test | infra | ...>",
        "difficulty": "<trivial | moderate | hard>",
        "risk": "<low | medium | high>"
      },
      "skills": {
        "<domain or quality the diff actually exercised>": {"score": <0-10>, "note": "<one line>"}
      }
    }

    `facets` is GROUND TRUTH — characterize what this task ACTUALLY was from the task spec and the
    REAL diff in front of you, not from any label it was filed under. Open vocabulary: add/rename keys
    as the work warrants; the five above are a starting set, not a fixed schema.

    `skills` is a two-axis rubric. Score ONLY the skills this diff genuinely exercised — leave the rest
    out, never pad with zeros:
    - programming domains touched — e.g. otp, ecto, phoenix, liveview, js, rust
    - cross-cutting qualities shown — e.g. concurrency, error_handling, idiom, test_rigor, security,
      docs, truthfulness (the implementer's self-report vs what you actually found)
    Each is a {"score": 0-10, "note": "..."} map; the note is your one-line evidence for the score.
    Open vocabulary — these are examples, not an enum.

    `checks` records the actual command(s) you ran and your own boolean pass/fail call for each.
    `concerns` is a list of caveats you are explicitly approving with; leave it [] only when there
    are none. If you approve with a dismissed red, the reproduced mechanism belongs here, not only in
    the report.
    `proposed_tasks` is a list of zero or more discovery proposals. Each entry needs `title`, `body`,
    `suggested_scores`, `suggested_markers`, and `evidence`; use [] when you found no follow-up work.
    Propose them here only — never file or edit roadmap/history files in this worktree.

    A missing or malformed #{Review.artifact_path()} fails this run.

    Project check hint (run these yourself; judge the output):
    #{Text.placeholder(data.project.check_command)}

    Implementer: #{data.item.agent}
    Current commit: #{current_sha(data)}

    Task spec:
    #{Text.placeholder(task_text(data))}

    Acceptance criteria:
    #{format_acceptance_criteria(data.item.acceptance_criteria)}

    Implementer transcript tail:
    #{Text.placeholder(transcript_tail(data.transcript))}

    Diff stat:
    #{Text.placeholder(diff_stat(data))}
    """
  end

  # The one piece of situational framing the reviewer needs: whether the
  # implementer actually committed anything. What an empty diff MEANS is the
  # reviewer's judgment, not a harness disposition branch.
  @doc false
  @spec reviewer_situation(data()) :: String.t()
  def reviewer_situation(%{implementer_empty_diff?: true}) do
    String.trim_trailing("""
    The implementer produced NO diff in this worktree. The transcript tail below shows what it
    did — it may have hit a usage limit, crashed, or believed the work was already done. Decide
    what the empty diff means:
    - Already implemented / you can implement it: do the work or verify it, run the checks, approve.
    - Nothing happened and nothing is salvageable: reject, and say why in your report.
    """)
  end

  def reviewer_situation(_data) do
    String.trim_trailing("""
    The implementer has committed work in this SAME worktree. It is yours to review, fix, and gate.
    """)
  end

  @doc false
  @spec transcript_tail(String.t()) :: String.t()
  def transcript_tail(transcript) when byte_size(transcript) <= @reviewer_transcript_tail_bytes, do: transcript

  def transcript_tail(transcript) do
    tail =
      binary_part(
        transcript,
        byte_size(transcript) - @reviewer_transcript_tail_bytes,
        @reviewer_transcript_tail_bytes
      )

    Text.valid_utf8_tail(tail)
  end

  @doc false
  @spec diff_stat(data()) :: String.t()
  def diff_stat(data) do
    case Git.run(["diff", "--stat", "#{data.worktree.base_sha}..HEAD"], data.worktree.path) do
      {:ok, stat} -> String.trim(stat)
      {:error, reason} -> "diff stat unavailable: #{inspect(reason)}"
    end
  end

  @doc false
  @spec reviewer_commit_message(data()) :: String.t()
  def reviewer_commit_message(data) do
    "harness: reviewer fixes — task #{data.item.id} #{data.item.title} (run #{data.run_id})"
  end
end
