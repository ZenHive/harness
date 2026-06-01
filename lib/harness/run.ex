defmodule Harness.Run do
  @moduledoc """
  The supervised lifecycle of one coding-agent job.

  A `Harness.Run` is a `:gen_statem` that owns one rmap task end to end: it
  creates an isolated git worktree, dispatches a headless agent into it, waits
  for the agent to terminate, runs the verification stack against the result,
  and settles on a verdict. It is the unit the project's CLAUDE.md calls "one
  run = one supervised gen_statem".

  ## States

      dispatched  — creating the isolated worktree
      running     — the agent is working in the worktree
      committing  — committing the agent's work to the run branch
      verifying   — the verification stack is grading the worktree
      consulting  — the opposite-agent grader is reviewing a repeated failure
      done        — verification graded the worktree green (terminal)
      failed      — anything else (terminal)

  Each state runs its slow work in a task *monitored, never linked* by the
  gen_statem, so a crashing step surfaces as an event rather than crashing the
  run. `done` and `failed` are terminal: the run delivers a `Harness.Run.Result`
  to its subscriber as `{:harness_run, run_id, result}`, lingers briefly so a
  late `status/1` still resolves, then stops `:normal`.

  ## Grading

  A run is graded green by the verification stack alone — never by the agent's
  exit code or self-reported result. The agent's `Harness.AgentAdapter.Outcome`
  is recorded for diagnostics, but a run whose agent timed out is still
  verified: the worktree it left behind is what gets graded.

  ## Repair loop

  A red verdict is not necessarily terminal. While repair attempts remain
  (`:max_repair_attempts`, default `2`) and the adapter can resume its session,
  `verifying` loops back to `running` instead of settling: the same agent is
  resumed with a prompt carrying the failing checks' output (see
  `Harness.Run.RepairPrompt`), re-commits, and is re-graded. The objective check
  stack stays the grader, so an agent iterating against it is repairing its
  work, not self-grading. The loop stops on green, on the attempt cap (settling
  `:failed` / `:verification_red`), or on any non-red terminal failure of a
  repair attempt — a quota-starved agent that produces no diff settles
  `:no_changes` rather than burning the remaining attempts. `repair_attempts` on
  both the result and the status snapshot reports how many attempts were made.

  ## Cancellation & timeout

  `cancel/1` aborts an in-flight run; a per-run lifetime budget does the same
  when it elapses. Both kill the in-flight step task and SIGKILL the agent if
  one is running, then settle `failed`. The lifetime budget is a last-resort
  deadline — it force-settles even when the agent run handle never arrived (a
  hung adapter `build_command`/`invoke`). In that race a just-spawned OS
  process whose pid was never received may leak; the boot-time
  `Harness.Worktree.Sweeper` reaps its working directory across restarts.
  Crash isolation is structural — each run is a `:temporary` child of
  `Harness.Run.Supervisor` (a `:one_for_one` DynamicSupervisor), so one run
  crashing never touches a sibling.

  ## Observability

  `status/1` returns a `Harness.Run.Status` snapshot at any point while the run
  is in flight or lingering in a terminal state.
  """

  @behaviour :gen_statem

  use Descripex, namespace: "/run"

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Driver
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Outcome
  alias Harness.AgentAdapter.Run, as: AgentRun
  alias Harness.AgentRegistry
  alias Harness.AuditReview
  alias Harness.Dashboard.RunFeed
  alias Harness.Dashboard.Transcript
  alias Harness.Dashboard.Transcript.Parser
  alias Harness.Git
  alias Harness.Lander.Resilience
  alias Harness.Lander.Worker, as: LanderWorker
  alias Harness.Oban, as: HarnessOban
  alias Harness.Project
  alias Harness.ResultStore
  alias Harness.Roadmap.Item
  alias Harness.Run.FailureClass
  alias Harness.Run.LogRecord
  alias Harness.Run.Reflex
  alias Harness.Run.RepairPrompt
  alias Harness.Run.Result
  alias Harness.Run.RetryPolicy
  alias Harness.Run.Status
  alias Harness.TokenUsage
  alias Harness.Verification
  alias Harness.Verification.Check
  alias Harness.Verification.Result, as: CheckResult
  alias Harness.Verification.Verdict
  alias Harness.Worktree
  alias Harness.Worktree.Isolation
  alias Oban.Job

  require Logger

  @registry Harness.Run.Registry
  @task_supervisor Harness.Run.TaskSupervisor

  @default_lifetime_timeout 5_400_000
  @default_terminal_linger 5_000
  @default_max_repair_attempts 2
  @semantic_diff_context_lines 80
  @semantic_diff_max_bytes 80_000

  @typedoc "A lifecycle state."
  @type state :: :dispatched | :running | :committing | :verifying | :consulting | :done | :failed

  @typedoc "A run handle: a run id, or the gen_statem pid directly."
  @type run :: String.t() | pid()

  @typedoc false
  @type init_arg :: {Item.t(), Project.t(), module(), keyword()}

  @typep data :: %{
           run_id: String.t(),
           item: Item.t(),
           project: Project.t(),
           adapter: module(),
           subscriber: pid() | nil,
           result_store: ResultStore.store(),
           batch_id: String.t(),
           started_at_ms: integer(),
           total_timeout: timeout() | nil,
           idle_timeout: timeout() | nil,
           progress_timeout: timeout() | nil,
           lifetime_timeout: pos_integer(),
           terminal_linger: non_neg_integer(),
           max_repair_attempts: non_neg_integer(),
           retry_policy: RetryPolicy.t(),
           repair_attempts: non_neg_integer(),
           repair_prompt_kind: :verification_red | :semantic_rejection | nil,
           cross_agent_repair: keyword(),
           semantic_gate: keyword(),
           consultation_kind: :repair | :semantic_gate | nil,
           last_failed_check_signatures: MapSet.t(term()),
           cross_agent_consulted: boolean(),
           cross_agent_follow_up: boolean(),
           cross_agent_feedback: %{verdict: AuditReview.verdict(), rationale: String.t()} | nil,
           checks: [Check.t()] | nil,
           verification_timeout: timeout() | nil,
           base_dir: String.t() | nil,
           base_ref: String.t() | nil,
           adapter_opts: keyword(),
           env: %{optional(String.t()) => String.t() | false},
           land_attempt: pos_integer(),
           worktree: Worktree.t() | nil,
           checkout_snapshot: String.t() | nil,
           pollution_allowlist: [String.t()],
           agent_run: AgentRun.t() | nil,
           agent_outcome: Outcome.t() | nil,
           composed_inputs: [AgentAdapter.composed_input()],
           verdict: Verdict.t() | nil,
           token_usage: TokenUsage.t(),
           first_attempt_failed_check_count: non_neg_integer(),
           agent_diff_size: non_neg_integer() | nil,
           task: Task.t() | nil,
           cancel_requested: {Result.reason(), :gen_statem.from() | nil} | nil,
           reason: Result.reason() | nil,
           result: Result.t() | nil,
           transcript: binary(),
           transcript_bytes: non_neg_integer(),
           transcript_seq: non_neg_integer(),
           agent_kind: Parser.agent_kind() | nil,
           transcript_events: [Parser.event()],
           transcript_parser_state: Parser.parser_state() | nil
         }

  @typep event :: :enter | :gen_statem.event_type()
  @typep handler_result ::
           :keep_state_and_data
           | {:keep_state_and_data, [:gen_statem.action()]}
           | {:keep_state, data()}
           | {:keep_state, data(), [:gen_statem.action()]}
           | {:next_state, state(), data()}
           | {:next_state, state(), data(), [:gen_statem.action()]}
           | {:stop, term(), data()}

  # ── Public API ────────────────────────────────────────────────────────────

  @doc false
  @spec child_spec(init_arg()) :: Supervisor.child_spec()
  def child_spec(arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}, restart: :temporary, type: :worker}
  end

  @doc false
  @spec start_link(init_arg()) :: :gen_statem.start_ret()
  def start_link({%Item{}, %Project{} = _project, adapter, opts} = arg) when is_atom(adapter) and is_list(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    :gen_statem.start_link({:via, Registry, {@registry, run_id}}, __MODULE__, arg, [])
  end

  api(:status, "Return a Harness.Run.Status snapshot of one in-flight or lingering-terminal run.",
    params: [
      run: [
        kind: :exchange_data,
        source: "Harness.Run.Supervisor.list_runs/0",
        description:
          "A run handle: run id string (from list_runs/0 or start_run/4) or the gen_statem pid directly. A run that has stopped is unregistered and returns {:error, :not_found}."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %Harness.Run.Status{}} carrying state, worktree_path, agent_os_pid, agent_kind, verdict_status, repair_attempts, reason. {:error, :not_found} for stopped/unknown runs."
    }
  )

  @spec status(run()) :: {:ok, Status.t()} | {:error, :not_found}
  def status(run) do
    with {:ok, pid} <- resolve(run) do
      {:ok, :gen_statem.call(pid, :status)}
    end
  catch
    :exit, _reason -> {:error, :not_found}
  end

  api(
    :transcript,
    "Return the buffered agent transcript and last seq tag for an in-flight or lingering run.",
    params: [
      run: [
        kind: :exchange_data,
        source: "Harness.Run.Supervisor.list_runs/0",
        description: "Run id string or gen_statem pid."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %{buffer: binary, seq: non_neg_integer}} — buffer is bounded at 200 KiB; seq is the monotonic counter for the last chunk (0 when nothing yet). {:error, :not_found} for stopped/unknown runs. Used by the dashboard transcript pane subscribe-then-snapshot pattern."
    }
  )

  @spec transcript(run()) ::
          {:ok, %{buffer: binary(), seq: non_neg_integer()}} | {:error, :not_found}
  def transcript(run) do
    with {:ok, pid} <- resolve(run) do
      {:ok, :gen_statem.call(pid, :transcript)}
    end
  catch
    :exit, _reason -> {:error, :not_found}
  end

  api(
    :transcript_events,
    "Return the parsed transcript event list + last seq tag for an in-flight or lingering run.",
    params: [
      run: [
        kind: :exchange_data,
        source: "Harness.Run.Supervisor.list_runs/0",
        description: "Run id string or gen_statem pid."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %{events: [Parser.event()], agent_kind: Parser.agent_kind() | nil, seq: non_neg_integer}} — events are the cumulative bounded list (default cap 500) parsed via Harness.Dashboard.Transcript.Parser; agent_kind is the executing adapter's atom (or nil for unregistered adapters / test doubles); seq mirrors transcript/1's counter. {:error, :not_found} for stopped/unknown runs."
    }
  )

  @spec transcript_events(run()) ::
          {:ok,
           %{
             events: [Parser.event()],
             agent_kind: Parser.agent_kind() | nil,
             seq: non_neg_integer()
           }}
          | {:error, :not_found}
  def transcript_events(run) do
    with {:ok, pid} <- resolve(run) do
      {:ok, :gen_statem.call(pid, :transcript_events)}
    end
  catch
    :exit, _reason -> {:error, :not_found}
  end

  api(:cancel, "Cancel an in-flight Harness.Run: kills the agent and settles the run :failed.",
    params: [
      run: [
        kind: :exchange_data,
        source: "Harness.Run.Supervisor.list_runs/0",
        description: "Run id string or gen_statem pid."
      ]
    ],
    returns: %{
      type: :atom,
      description: ":ok — idempotent. Cancelling an already-settled or unknown run is a no-op."
    }
  )

  @spec cancel(run()) :: :ok
  def cancel(run) do
    case resolve(run) do
      {:ok, pid} -> :gen_statem.call(pid, :cancel)
      {:error, :not_found} -> :ok
    end
  catch
    :exit, _reason -> :ok
  end

  @spec resolve(run()) :: {:ok, pid()} | {:error, :not_found}
  defp resolve(pid) when is_pid(pid), do: {:ok, pid}

  defp resolve(run_id) when is_binary(run_id) do
    case Registry.lookup(@registry, run_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  # ── gen_statem setup ──────────────────────────────────────────────────────

  @doc false
  @impl :gen_statem
  @spec callback_mode() :: [:state_functions | :state_enter]
  def callback_mode, do: [:state_functions, :state_enter]

  @doc false
  @impl :gen_statem
  @spec init(init_arg()) :: {:ok, :dispatched, data(), [:gen_statem.action()]}
  def init({item, %Project{} = project, adapter, opts}) do
    run_id = Keyword.fetch!(opts, :run_id)

    data = %{
      run_id: run_id,
      item: item,
      project: project,
      adapter: adapter,
      subscriber: Keyword.get(opts, :subscriber),
      result_store: Keyword.get(opts, :result_store, ResultStore.configured()),
      batch_id: Keyword.get(opts, :batch_id) || run_id,
      started_at_ms: System.monotonic_time(:millisecond),
      total_timeout: Keyword.get(opts, :total_timeout),
      idle_timeout: Keyword.get(opts, :idle_timeout),
      progress_timeout: Keyword.get(opts, :progress_timeout),
      lifetime_timeout:
        Keyword.get(opts, :lifetime_timeout) ||
          configured(:lifetime_timeout, @default_lifetime_timeout),
      terminal_linger:
        Keyword.get(opts, :terminal_linger) ||
          configured(:terminal_linger, @default_terminal_linger),
      max_repair_attempts:
        Keyword.get(opts, :max_repair_attempts) ||
          configured(:max_repair_attempts, @default_max_repair_attempts),
      retry_policy: RetryPolicy.from_opts(opts),
      repair_attempts: 0,
      repair_prompt_kind: nil,
      cross_agent_repair: cross_agent_repair_opts(opts),
      semantic_gate: semantic_gate_opts(opts),
      consultation_kind: nil,
      last_failed_check_signatures: MapSet.new(),
      cross_agent_consulted: false,
      cross_agent_follow_up: false,
      cross_agent_feedback: nil,
      checks: Keyword.get(opts, :checks),
      verification_timeout: Keyword.get(opts, :verification_timeout),
      base_dir: Keyword.get(opts, :base_dir),
      base_ref: Keyword.get(opts, :base_ref),
      adapter_opts: Keyword.get(opts, :adapter_opts, []),
      env: Keyword.get(opts, :env, %{}),
      land_attempt: Keyword.get(opts, :land_attempt, 1),
      worktree: nil,
      checkout_snapshot: nil,
      pollution_allowlist: resolve_pollution_allowlist(project, opts),
      agent_run: nil,
      agent_outcome: nil,
      composed_inputs: [],
      verdict: nil,
      token_usage: TokenUsage.empty(),
      first_attempt_failed_check_count: 0,
      agent_diff_size: nil,
      task: nil,
      cancel_requested: nil,
      reason: nil,
      result: nil,
      transcript: <<>>,
      transcript_bytes: 0,
      transcript_seq: 0,
      agent_kind: agent_kind_for(adapter),
      transcript_events: [],
      transcript_parser_state: init_parser_state(adapter)
    }

    {:ok, :dispatched, data, [{{:timeout, :lifetime}, data.lifetime_timeout, :lifetime}]}
  end

  # ── State: dispatched — carve the isolated worktree ───────────────────────

  @doc false
  @spec dispatched(event(), term(), data()) :: handler_result()
  def dispatched(:enter, _old_state, data) do
    RunFeed.broadcast_update(status_snapshot(:dispatched, data))
    task = start_task(fn -> Worktree.create(data.project, worktree_opts(data)) end)
    {:keep_state, %{data | task: task}}
  end

  def dispatched(:info, {ref, {:ok, %Worktree{} = worktree}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    data = %{data | task: nil, worktree: worktree}

    with :ok <- Worktree.activate(worktree),
         :ok <- Isolation.validate(data.adapter) do
      {:next_state, :running, data}
    else
      {:error, {:worktree_isolation_unsupported, _adapter, _message} = reason} ->
        fail(data, {:agent_spawn_failed, reason})

      {:error, reason} ->
        fail(data, {:worktree_failed, reason})
    end
  end

  def dispatched(:info, {ref, {:error, reason}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    fail(%{data | task: nil}, {:worktree_failed, reason})
  end

  def dispatched(:info, {:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = data) when reason != :normal do
    fail(%{data | task: nil}, {:worktree_failed, reason})
  end

  def dispatched(event_type, event_content, data) do
    handle_common(event_type, event_content, :dispatched, data)
  end

  # ── State: running — the agent works in the worktree ──────────────────────

  @doc false
  @spec running(event(), term(), data()) :: handler_result()
  # Entering `running` always means a fresh agent is about to spawn — the first
  # dispatch, or a repair attempt. `agent_run` / `agent_outcome` are reset so a
  # stale handle from a prior attempt never misleads the cancel-defer logic or a
  # `status/1` snapshot.
  def running(:enter, _old_state, data) do
    RunFeed.broadcast_update(status_snapshot(:running, data))
    parent = self()
    invocation = build_invocation(data)
    checkout_snapshot = checkout_snapshot_for_run(data)
    task = start_task(fn -> Driver.run(data.adapter, invocation, driver_opts(data, parent)) end)

    {:keep_state,
     %{
       data
       | task: task,
         checkout_snapshot: checkout_snapshot,
         agent_run: nil,
         agent_outcome: nil
     }}
  end

  def running(:info, {:run_handle, %AgentRun{} = run}, data) do
    data = %{
      data
      | agent_run: run,
        composed_inputs: data.composed_inputs ++ [tag_composed_input(run, data)]
    }

    case data.cancel_requested do
      nil -> {:keep_state, data}
      {reason, from} -> do_cancel(data, reason, from)
    end
  end

  def running(:info, {ref, {:ok, %Outcome{} = outcome}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])

    data =
      %{data | task: nil, agent_outcome: outcome}
      |> finalize_transcript()
      |> accumulate_token_usage(outcome)

    # Precedence: a user cancel is terminal and must win over reflex re-dispatch,
    # so the reflex clause is gated on `nil` cancel. A cancelled run that also
    # tripped a reflex falls through to do_cancel / pollution rather than being
    # re-dispatched. Pollution still beats cancel (unchanged).
    case {data.cancel_requested, outcome.kind, checkout_pollution_reason(data)} do
      {nil, {:reflex_halted, reason}, _pollution_reason} ->
        route_reflex_halt(data, reason)
        fail(data, {:reflex_halted, reason})

      {nil, _kind, nil} ->
        {:next_state, :committing, data}

      {{reason, from}, _kind, nil} ->
        do_cancel(data, reason, from)

      {_, _kind, pollution_reason} ->
        fail(data, pollution_reason)
    end
  end

  def running(:info, {ref, {:error, reason}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    fail(%{data | task: nil}, {:agent_spawn_failed, reason})
  end

  def running(:info, {:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = data) when reason != :normal do
    # Mirrors the do_cancel / timeout paths: if the agent polluted the main
    # checkout AND then crashed the driver, surface the pollution (the agent
    # bug) ahead of the driver crash (the downstream effect).
    pollution_reason = checkout_pollution_reason(data)
    fail(%{data | task: nil}, pollution_reason || {:driver_crashed, reason})
  end

  def running(event_type, event_content, data) do
    handle_common(event_type, event_content, :running, data)
  end

  # ── State: committing — capture the agent's work on the run branch ────────

  @doc false
  @spec committing(event(), term(), data()) :: handler_result()
  def committing(:enter, _old_state, data) do
    RunFeed.broadcast_update(status_snapshot(:committing, data))
    worktree = data.worktree
    message = commit_message(data)
    task = start_task(fn -> commit_worktree(worktree, message) end)
    {:keep_state, %{data | task: task}}
  end

  def committing(:info, {ref, {:ok, :committed, diff_size}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    {:next_state, :verifying, %{data | task: nil, agent_diff_size: diff_size}}
  end

  def committing(:info, {ref, {:ok, :no_changes, diff_size}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    fail(%{data | task: nil, agent_diff_size: diff_size}, :no_changes)
  end

  def committing(:info, {ref, {:error, reason}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    fail(%{data | task: nil}, {:commit_failed, reason})
  end

  def committing(:info, {:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = data) when reason != :normal do
    fail(%{data | task: nil}, {:commit_failed, reason})
  end

  def committing(event_type, event_content, data) do
    handle_common(event_type, event_content, :committing, data)
  end

  # ── State: verifying — grade the worktree ─────────────────────────────────

  @doc false
  @spec verifying(event(), term(), data()) :: handler_result()
  def verifying(:enter, _old_state, data) do
    RunFeed.broadcast_update(status_snapshot(:verifying, data))
    worktree = data.worktree
    task = start_task(fn -> Verification.run(worktree.path, verification_opts(data)) end)
    {:keep_state, %{data | task: task}}
  end

  def verifying(:info, {ref, {:ok, %Verdict{} = verdict}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])

    data = %{
      data
      | task: nil,
        verdict: verdict,
        first_attempt_failed_check_count: first_attempt_failed_check_count(data, verdict)
    }

    failed_signatures = failed_check_signatures(verdict)

    cond do
      Verdict.passed?(verdict) and semantic_gate_enabled?(data) ->
        {:next_state, :consulting, %{data | consultation_kind: :semantic_gate}}

      Verdict.passed?(verdict) ->
        {:next_state, :done, %{data | reason: :passed, repair_prompt_kind: nil}}

      data.cross_agent_follow_up ->
        {:next_state, :failed, %{data | reason: :verification_red, last_failed_check_signatures: failed_signatures}}

      cross_agent_repairable?(data, failed_signatures) ->
        data = %{
          data
          | repair_attempts: data.repair_attempts + 1,
            last_failed_check_signatures: failed_signatures,
            repair_prompt_kind: :verification_red,
            consultation_kind: :repair,
            cross_agent_consulted: true
        }

        {:next_state, :consulting, data}

      repairable?(data) ->
        # Loop back to `running`: the same agent is resumed with the failing
        # checks fed back. `build_invocation/1` reads the incremented count.
        data = %{
          data
          | repair_attempts: data.repair_attempts + 1,
            last_failed_check_signatures: failed_signatures,
            repair_prompt_kind: :verification_red
        }

        {:next_state, :running, data}

      true ->
        {:next_state, :failed, %{data | reason: :verification_red, last_failed_check_signatures: failed_signatures}}
    end
  end

  def verifying(:info, {ref, {:error, reason}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    fail(%{data | task: nil}, {:verification_failed, reason})
  end

  def verifying(:info, {:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = data) when reason != :normal do
    fail(%{data | task: nil}, {:verifier_crashed, reason})
  end

  def verifying(event_type, event_content, data) do
    handle_common(event_type, event_content, :verifying, data)
  end

  # ── State: consulting — one-shot opposite-agent grader ───────────────────

  @doc false
  @spec consulting(event(), term(), data()) :: handler_result()
  def consulting(:enter, _old_state, data) do
    RunFeed.broadcast_update(status_snapshot(:consulting, data))
    task = start_task(fn -> grade_consultation(data) end)
    {:keep_state, %{data | task: task}}
  end

  def consulting(:info, {ref, {:ok, %{verdict: verdict, outcome: %Outcome{} = outcome}}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])

    feedback = %{
      verdict: verdict,
      rationale: cross_agent_rationale(outcome.output)
    }

    data = %{data | task: nil}

    case data.consultation_kind do
      :semantic_gate ->
        handle_semantic_gate_verdict(data, verdict, feedback)

      _repair ->
        data = %{
          data
          | cross_agent_feedback: feedback,
            cross_agent_follow_up: true,
            consultation_kind: nil
        }

        {:next_state, :running, data}
    end
  end

  def consulting(:info, {ref, {:error, reason}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])

    case data.consultation_kind do
      :semantic_gate ->
        Logger.warning("harness run: semantic gate grader failed for #{data.run_id}: #{inspect(reason)}")

        reject_semantic_gate(%{data | task: nil}, semantic_gate_failure_feedback(reason))

      _repair ->
        Logger.warning("harness run: cross-agent repair grader failed for #{data.run_id}: #{inspect(reason)}")

        {:next_state, :failed, %{data | task: nil, reason: :verification_red, consultation_kind: nil}}
    end
  end

  def consulting(:info, {:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = data) when reason != :normal do
    case data.consultation_kind do
      :semantic_gate ->
        Logger.warning("harness run: semantic gate grader crashed for #{data.run_id}: #{inspect(reason)}")

        reject_semantic_gate(
          %{data | task: nil},
          semantic_gate_failure_feedback({:crashed, reason})
        )

      _repair ->
        Logger.warning("harness run: cross-agent repair grader crashed for #{data.run_id}: #{inspect(reason)}")

        {:next_state, :failed, %{data | task: nil, reason: :verification_red, consultation_kind: nil}}
    end
  end

  def consulting(event_type, event_content, data) do
    handle_common(event_type, event_content, :consulting, data)
  end

  # ── States: done / failed — terminal ──────────────────────────────────────

  @doc false
  @spec done(event(), term(), data()) :: handler_result()
  def done(:enter, _old_state, data) do
    data = settle(data, :done)
    {:keep_state, data, [{:state_timeout, data.terminal_linger, :shutdown}]}
  end

  def done(:state_timeout, :shutdown, data), do: {:stop, :normal, data}

  def done(event_type, event_content, data) do
    handle_common(event_type, event_content, :done, data)
  end

  @doc false
  @spec failed(event(), term(), data()) :: handler_result()
  def failed(:enter, _old_state, data) do
    data = settle(data, :failed)
    {:keep_state, data, [{:state_timeout, data.terminal_linger, :shutdown}]}
  end

  def failed(:state_timeout, :shutdown, data), do: {:stop, :normal, data}

  def failed(event_type, event_content, data) do
    handle_common(event_type, event_content, :failed, data)
  end

  # ── Cross-cutting events ──────────────────────────────────────────────────

  # Events handled the same way in every state: status queries, cancellation,
  # the lifetime timeout, and stale messages from tasks already consumed or
  # killed.
  @spec handle_common(event(), term(), state(), data()) :: handler_result()
  defp handle_common({:call, from}, :status, state, data) do
    {:keep_state_and_data, [{:reply, from, status_snapshot(state, data)}]}
  end

  defp handle_common({:call, from}, :transcript, _state, data) do
    snapshot = %{buffer: data.transcript, seq: data.transcript_seq}
    {:keep_state_and_data, [{:reply, from, snapshot}]}
  end

  defp handle_common({:call, from}, :transcript_events, _state, data) do
    snapshot = %{
      events: data.transcript_events,
      agent_kind: data.agent_kind,
      seq: data.transcript_seq
    }

    {:keep_state_and_data, [{:reply, from, snapshot}]}
  end

  # State-agnostic so a chunk that lands during `:committing` / `:verifying` /
  # `:terminal_linger` still appends — the agent's Port can flush after the
  # gen_statem has already transitioned out of `:running`.
  #
  # Two parallel buffers + broadcasts per chunk: the legacy raw iodata path
  # (Transcript.append/broadcast) keeps `?raw=1` on the run-detail URL alive
  # for one release; the parsed-event path (Transcript.append_chunk/4 +
  # broadcast_events/3) feeds the new `<.transcript_view>` renderer. Subscribers
  # pattern-match whichever shape they want.
  defp handle_common(:info, {:transcript_chunk, chunk}, _state, data) do
    {trimmed, trimmed_bytes} = Transcript.append(data.transcript, data.transcript_bytes, chunk)
    new_seq = data.transcript_seq + 1
    Transcript.broadcast(data.run_id, new_seq, chunk)

    {new_events, delta, new_parser_state} = parse_chunk(data, chunk)
    if delta != [], do: Transcript.broadcast_events(data.run_id, new_seq, delta)

    {:keep_state,
     %{
       data
       | transcript: trimmed,
         transcript_bytes: trimmed_bytes,
         transcript_seq: new_seq,
         transcript_events: new_events,
         transcript_parser_state: new_parser_state
     }}
  end

  defp handle_common({:call, from}, :cancel, state, _data) when state in [:done, :failed] do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  defp handle_common({:call, from}, :cancel, :running, %{agent_run: nil} = data) do
    # The agent has spawned but its handle has not arrived yet — defer the
    # cancel until {:run_handle, _} lands, so the agent can actually be killed.
    {:keep_state, %{data | cancel_requested: {:cancelled, from}}}
  end

  defp handle_common({:call, from}, :cancel, _state, data) do
    do_cancel(data, :cancelled, from)
  end

  defp handle_common({:timeout, :lifetime}, :lifetime, state, _data) when state in [:done, :failed] do
    :keep_state_and_data
  end

  defp handle_common({:timeout, :lifetime}, :lifetime, _state, data) do
    force_settle_lifetime(data)
  end

  # Stale task messages (a result or DOWN from a task already consumed or
  # killed) and any other unrecognised info — ignored.
  defp handle_common(:info, _content, _state, _data), do: :keep_state_and_data

  # Defensive catch-all for any other event type.
  defp handle_common(_type, _content, _state, _data), do: :keep_state_and_data

  # ── Cancellation & settling ───────────────────────────────────────────────

  # Aborts an in-flight run: kills the current step task, SIGKILLs the agent if
  # one is running, and settles `failed`. `from` is the caller awaiting a cancel
  # reply, or `nil` for a timeout-triggered abort.
  @spec do_cancel(data(), Result.reason(), :gen_statem.from() | nil) :: handler_result()
  defp do_cancel(data, reason, from) do
    cancel_task(data.task)
    terminate_agent(data)
    reason = checkout_pollution_reason(data) || reason
    data = %{data | task: nil, agent_run: nil, cancel_requested: nil, reason: reason}
    actions = if from, do: [{:reply, from, :ok}], else: []
    {:next_state, :failed, data, actions}
  end

  # Force-settles `:failed` with `:timed_out` when the lifetime budget elapses.
  # The lifetime timer is the last-resort deadline: it fires regardless of
  # whether `{:run_handle, _}` has arrived, so a hung adapter
  # `build_command`/`invoke` cannot wedge the run forever. Trade-off: with
  # `agent_run: nil` there is nothing to SIGKILL directly — killing the driver
  # task closes its port and a just-spawned OS process whose pid we never
  # received may leak. The boot-time `Harness.Worktree.Sweeper` reaps its
  # working directory across restarts. A deferred cancel caller (a real
  # `cancel/1` that arrived before the agent handle) still gets `:ok`.
  @spec force_settle_lifetime(data()) :: handler_result()
  defp force_settle_lifetime(data) do
    cancel_task(data.task)
    terminate_agent(data)
    actions = pending_cancel_reply(data)
    reason = checkout_pollution_reason(data) || :timed_out
    data = %{data | task: nil, agent_run: nil, cancel_requested: nil, reason: reason}
    {:next_state, :failed, data, actions}
  end

  # Settles `failed` with `reason`, replying to a deferred cancel caller if one
  # is waiting — a cancel arrived before the agent handle, then the run failed
  # for another cause before the cancel could be honoured.
  #
  # The agent may still be alive — a driver-task crash leaves its OS process
  # running with nothing left to idle-time it out — so SIGKILL it here. A
  # crashed step must never orphan an agent (and its API quota).
  # `terminate_agent/1` is a no-op when no agent spawned and idempotent when it
  # already exited.
  @spec fail(data(), Result.reason()) :: handler_result()
  defp fail(data, reason) do
    terminate_agent(data)

    {:next_state, :failed, %{data | agent_run: nil, cancel_requested: nil, reason: reason}, pending_cancel_reply(data)}
  end

  @spec pending_cancel_reply(data()) :: [:gen_statem.action()]
  defp pending_cancel_reply(%{cancel_requested: {_reason, from}}) when is_tuple(from) do
    [{:reply, from, :ok}]
  end

  defp pending_cancel_reply(_data), do: []

  @spec cancel_task(Task.t() | nil) :: :ok
  defp cancel_task(nil), do: :ok

  defp cancel_task(%Task{} = task) do
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  @spec terminate_agent(data()) :: :ok
  defp terminate_agent(%{agent_run: nil}), do: :ok

  defp terminate_agent(%{agent_run: %AgentRun{} = run, adapter: adapter}) do
    adapter.terminate(run)
    :ok
  end

  @spec route_reflex_halt(data(), term()) :: :ok
  defp route_reflex_halt(data, reason) do
    case Resilience.route({:reflex_halt, reason}, resilience_args(data)) do
      :ok ->
        :ok

      {:cancel, {:blocked, blocked_reason}} ->
        Logger.warning("harness run: reflex halt blocked task #{data.item.id}: #{blocked_reason}")

      {:error, route_reason} ->
        Logger.warning("harness run: reflex halt route failed for task #{data.item.id}: #{inspect(route_reason)}")
    end

    :ok
  end

  @spec resilience_args(data()) :: map()
  defp resilience_args(data) do
    %{
      "project_name" => data.project.name,
      "run_id" => data.run_id,
      "task_id" => to_string(data.item.id),
      "agent" => to_string(data.item.agent),
      "branch" => "harness/" <> data.run_id,
      "land_attempt" => data.land_attempt
    }
  end

  # Builds and persists the final result, tears the worktree down, then delivers
  # it to the subscriber. Teardown errors are logged and swallowed so the result
  # is still delivered, but subscribers do not race test/driver fixture cleanup.
  @spec settle(data(), Result.state()) :: data()
  defp settle(data, terminal_state) do
    result = build_result(data, terminal_state)
    data = %{data | result: result}
    persist_run_record(data, result)
    finish_worktree(data.worktree, terminal_state)
    notify_subscriber(data.subscriber, data.run_id, result)
    RunFeed.broadcast_settled(status_snapshot(terminal_state, data))
    maybe_enqueue_landing(data, terminal_state)
    data
  end

  # Autonomous merge-train trigger: a run that settles green under a project that
  # opts into landing (`landing_policy: :auto` + a non-empty `target_branch`)
  # enqueues exactly one landing job onto the project's serialized `landing_<name>`
  # queue. Every other terminal state — red verdict, failure, `:manual` project,
  # or a project with no `target_branch` — enqueues nothing.
  @spec maybe_enqueue_landing(data(), Result.state()) :: :ok
  defp maybe_enqueue_landing(
         %{reason: :passed, project: %Project{landing_policy: :auto, target_branch: tb} = project} = data,
         :done
       )
       when is_binary(tb) and tb != "" do
    %{
      "project_name" => project.name,
      "run_id" => data.run_id,
      "task_id" => to_string(data.item.id),
      "agent" => to_string(data.item.agent),
      "branch" => "harness/" <> data.run_id,
      "land_attempt" => data.land_attempt
    }
    |> LanderWorker.new(queue: HarnessOban.landing_queue_name(project))
    |> HarnessOban.insert()
    |> log_landing_enqueue(data.run_id)
  end

  defp maybe_enqueue_landing(_data, _terminal_state), do: :ok

  @spec log_landing_enqueue({:ok, Job.t()} | {:error, term()}, String.t()) :: :ok
  defp log_landing_enqueue({:ok, _job}, run_id) do
    Logger.info("harness run: enqueued autonomous landing for run #{run_id}")
    :ok
  end

  defp log_landing_enqueue({:error, reason}, run_id) do
    Logger.warning("harness run: failed to enqueue landing for run #{run_id}: #{inspect(reason)}")
    :ok
  end

  @spec build_result(data(), Result.state()) :: Result.t()
  defp build_result(data, terminal_state) do
    %Result{
      run_id: data.run_id,
      task_id: data.item.id,
      state: terminal_state,
      reason: data.reason,
      agent_outcome: data.agent_outcome,
      verdict: data.verdict,
      worktree_path: data.worktree && data.worktree.path,
      repair_attempts: data.repair_attempts,
      first_attempt_failed_check_count: data.first_attempt_failed_check_count,
      agent_diff_size: data.agent_diff_size,
      token_usage: data.token_usage,
      composed_inputs: data.composed_inputs
    }
  end

  # Parses the just-settled attempt's transcript for token usage and sums it into
  # the run's running total, so a multi-attempt repair loop's burn is attributable.
  # `agent_kind: nil` (test doubles, unregistered adapters) parses to an empty
  # usage, so the total stays an empty usage — never a crash.
  @spec accumulate_token_usage(data(), Outcome.t()) :: data()
  defp accumulate_token_usage(data, %Outcome{output: output}) do
    attempt = TokenUsage.parse(data.agent_kind, output)
    %{data | token_usage: TokenUsage.add(data.token_usage, attempt)}
  end

  @spec persist_run_record(data(), Result.t()) :: :ok
  defp persist_run_record(data, %Result{} = result) do
    result
    |> LogRecord.from_result(
      batch_id: data.batch_id,
      agent: data.item.agent,
      adapter: data.adapter,
      project_name: data.project.name,
      duration_ms: run_duration_ms(data),
      domains: data.item.domains
    )
    |> ResultStore.record_run(data.result_store)
    |> log_store_error(result.run_id)
  end

  @spec log_store_error(:ok | {:error, term()}, String.t()) :: :ok
  defp log_store_error(:ok, _run_id), do: :ok

  defp log_store_error({:error, reason}, run_id) do
    Logger.warning("harness run: failed to persist run record #{run_id}: #{inspect(reason)}")
    :ok
  end

  @spec run_duration_ms(data()) :: non_neg_integer()
  defp run_duration_ms(data) do
    max(0, System.monotonic_time(:millisecond) - data.started_at_ms)
  end

  @spec notify_subscriber(pid() | nil, String.t(), Result.t()) :: :ok
  defp notify_subscriber(nil, _run_id, _result), do: :ok

  defp notify_subscriber(subscriber, run_id, result) do
    send(subscriber, {:harness_run, run_id, result})
    :ok
  end

  @spec finish_worktree(Worktree.t() | nil, Result.state()) :: :ok
  defp finish_worktree(nil, _terminal_state), do: :ok

  defp finish_worktree(%Worktree{} = worktree, terminal_state) do
    outcome = if terminal_state == :done, do: :success, else: :failure

    case Worktree.finish(worktree, outcome) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("harness run: worktree finish failed for #{worktree.path}: #{inspect(reason)}")

        :ok
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  @spec status_snapshot(state(), data()) :: Status.t()
  defp status_snapshot(state, data) do
    %Status{
      run_id: data.run_id,
      task_id: data.item.id,
      project_name: data.project.name,
      state: state,
      worktree_path: data.worktree && data.worktree.path,
      agent_os_pid: data.agent_run && data.agent_run.os_pid,
      agent_kind: data.agent_outcome && data.agent_outcome.kind,
      verdict_status: data.verdict && data.verdict.status,
      repair_attempts: data.repair_attempts,
      reason: data.reason
    }
  end

  @spec start_task((-> term())) :: Task.t()
  defp start_task(fun) do
    Task.Supervisor.async_nolink(@task_supervisor, fun)
  end

  # The first dispatch runs the task prompt fresh; a repair attempt resumes the
  # agent's session with a prompt carrying the failing checks (RepairPrompt).
  @spec build_invocation(data()) :: Invocation.t()
  defp build_invocation(%{repair_attempts: 0} = data) do
    invocation(data, data.item.prompt, nil)
  end

  defp build_invocation(%{repair_prompt_kind: :semantic_rejection} = data) do
    invocation(data, semantic_repair_prompt(data), :resume)
  end

  defp build_invocation(%{verdict: %Verdict{} = verdict} = data) do
    prompt =
      RepairPrompt.build(data.item, verdict, data.repair_attempts, data.max_repair_attempts)

    prompt = add_cross_agent_feedback(prompt, data.cross_agent_feedback)
    invocation(data, prompt, :resume)
  end

  @spec invocation(data(), String.t(), :resume | nil) :: Invocation.t()
  defp invocation(data, prompt, session) do
    %Invocation{
      prompt: prompt,
      cwd: data.worktree.path,
      task_id: data.item.id,
      session: session,
      permission_mode: :autonomous,
      language: project_language(data.project),
      adapter_opts: data.adapter_opts,
      env: data.env
    }
  end

  @spec tag_composed_input(AgentRun.t(), data()) :: AgentAdapter.composed_input()
  defp tag_composed_input(%AgentRun{composed_input: input}, data) when is_map(input) do
    input
    |> Map.put(:attempt, data.repair_attempts)
    |> Map.put(:phase, composed_input_phase(data))
  end

  defp tag_composed_input(%AgentRun{}, data) do
    %{
      executable: "",
      argv: [],
      rule_channel: data.adapter.rule_channel(),
      prompt: "",
      session: nil,
      rule_files: [],
      attempt: data.repair_attempts,
      phase: composed_input_phase(data)
    }
  end

  @spec composed_input_phase(data()) :: :initial | :repair
  defp composed_input_phase(%{repair_attempts: 0}), do: :initial
  defp composed_input_phase(_data), do: :repair

  @spec project_language(Project.t()) :: atom() | nil
  defp project_language(%Project{check_stacks: [%{name: language}]}) when is_atom(language), do: language
  defp project_language(%Project{}), do: nil

  # Whether a red verdict should trigger another repair attempt: the cap is not
  # yet spent, the adapter can resume its session, and the failed attempt did
  # not already classify as quota exhaustion.
  @spec repairable?(data()) :: boolean()
  defp repairable?(data) do
    data.repair_attempts < data.max_repair_attempts and
      AgentAdapter.supports?(data.adapter, :session_resume) and
      failure_class(data) != :quota_exhausted
  end

  @spec cross_agent_repairable?(data(), MapSet.t(term())) :: boolean()
  defp cross_agent_repairable?(data, failed_signatures) do
    cross_agent_repair_enabled?(data) and
      cross_agent_grader_available?(data) and
      not data.cross_agent_consulted and
      repeated_failure?(data.last_failed_check_signatures, failed_signatures) and
      repairable?(data)
  end

  # AuditReview only auto-pairs `:claude ↔ :codex`; other implementers
  # (`:grok`, `:cursor`, `:antigravity`, `:pi`) need an explicit `:grader`
  # in :cross_agent_repair opts. Without one, `AuditReview.grade_fix/1`
  # returns `{:no_default_grader, _}` and the consulting transition would
  # short-circuit the same-agent repair loop. Guard here so dispatch falls
  # back to the normal repair path instead.
  @spec cross_agent_grader_available?(data()) :: boolean()
  defp cross_agent_grader_available?(data) do
    case Keyword.get(data.cross_agent_repair, :grader) do
      nil ->
        case AuditReview.default_grader(data.item.agent) do
          {:ok, _module} -> true
          {:error, _reason} -> false
        end

      _explicit_grader ->
        true
    end
  end

  @spec failure_class(data()) :: FailureClass.t()
  defp failure_class(data) do
    data
    |> Map.put(:reason, :verification_red)
    |> build_result(:failed)
    |> FailureClass.classify(data.retry_policy)
  end

  @spec grade_consultation(data()) :: {:ok, AuditReview.result()} | {:error, term()}
  defp grade_consultation(%{consultation_kind: :semantic_gate} = data), do: grade_semantic_gate(data)

  defp grade_consultation(data), do: grade_repair_approach(data)

  @spec grade_repair_approach(data()) :: {:ok, AuditReview.result()} | {:error, term()}
  defp grade_repair_approach(data) do
    opts = data.cross_agent_repair

    [
      implementer: data.item.agent,
      sha: current_sha(data),
      prompt: cross_agent_prompt(data),
      cwd: data.worktree.path
    ]
    |> put_opt(:grader, Keyword.get(opts, :grader))
    |> put_opt(:model, Keyword.get(opts, :model))
    |> put_opt(:adapter_opts, Keyword.get(opts, :adapter_opts))
    |> put_opt(:total_timeout, Keyword.get(opts, :total_timeout))
    |> put_opt(:idle_timeout, Keyword.get(opts, :idle_timeout))
    |> AuditReview.grade_fix()
  end

  @spec grade_semantic_gate(data()) :: {:ok, AuditReview.result()} | {:error, term()}
  defp grade_semantic_gate(data) do
    opts = data.semantic_gate

    with :ok <- ensure_cross_family_semantic_grader(data.item.agent, Keyword.get(opts, :grader)),
         {:ok, diff} <- committed_diff(data) do
      [
        implementer: data.item.agent,
        sha: current_sha(data),
        prompt: semantic_gate_prompt(data, diff),
        cwd: data.worktree.path
      ]
      |> put_opt(:grader, Keyword.get(opts, :grader))
      |> put_opt(:model, Keyword.get(opts, :model))
      |> put_opt(:adapter_opts, Keyword.get(opts, :adapter_opts))
      |> put_opt(:total_timeout, Keyword.get(opts, :total_timeout))
      |> put_opt(:idle_timeout, Keyword.get(opts, :idle_timeout))
      |> AuditReview.grade_fix()
    end
  end

  @spec ensure_cross_family_semantic_grader(atom(), atom() | nil) :: :ok | {:error, term()}
  defp ensure_cross_family_semantic_grader(_implementer, nil), do: :ok

  defp ensure_cross_family_semantic_grader(implementer, grader) do
    case known_grader_agent(grader) do
      {:ok, ^implementer} -> {:error, {:same_family_grader, implementer, grader}}
      _other -> :ok
    end
  end

  @spec known_grader_agent(atom()) :: {:ok, atom()} | :unknown
  defp known_grader_agent(grader) do
    case AgentRegistry.module_for_agent(grader) do
      {:ok, _module} ->
        {:ok, grader}

      {:error, _reason} ->
        case AgentRegistry.agent_for_module(grader) do
          {:ok, agent} -> {:ok, agent}
          {:error, _reason} -> :unknown
        end
    end
  end

  @spec handle_semantic_gate_verdict(data(), AuditReview.verdict(), %{
          verdict: AuditReview.verdict(),
          rationale: String.t()
        }) ::
          handler_result()
  defp handle_semantic_gate_verdict(data, :approve, _feedback) do
    {:next_state, :done, %{data | reason: :passed, consultation_kind: nil, repair_prompt_kind: nil}}
  end

  defp handle_semantic_gate_verdict(data, _verdict, feedback) do
    reject_semantic_gate(data, feedback)
  end

  @spec reject_semantic_gate(data(), %{verdict: AuditReview.verdict(), rationale: String.t()}) ::
          handler_result()
  defp reject_semantic_gate(data, feedback) do
    data = %{
      data
      | consultation_kind: nil,
        cross_agent_feedback: feedback,
        reason: :semantic_rejection
    }

    if semantic_repairable?(data) do
      {:next_state, :running,
       %{
         data
         | repair_attempts: data.repair_attempts + 1,
           repair_prompt_kind: :semantic_rejection
       }}
    else
      {:next_state, :failed, data}
    end
  end

  @spec semantic_repairable?(data()) :: boolean()
  defp semantic_repairable?(data) do
    data.repair_attempts < data.max_repair_attempts and
      AgentAdapter.supports?(data.adapter, :session_resume)
  end

  @spec semantic_gate_failure_feedback(term()) :: %{verdict: :reject, rationale: String.t()}
  defp semantic_gate_failure_feedback(reason) do
    %{
      verdict: :reject,
      rationale: "Semantic gate did not approve the diff: #{inspect(reason)}"
    }
  end

  @spec cross_agent_prompt(data()) :: String.t()
  defp cross_agent_prompt(data) do
    repair_prompt =
      RepairPrompt.build(data.item, data.verdict, data.repair_attempts, data.max_repair_attempts)

    """
    You are the one-shot opposite-agent grader for a harness repair loop.

    Grade the asker's proposed approach before the asker spends the next repair attempt.
    This is asymmetric grading, not dialogue. Do not ask questions and do not propose a back-and-forth.

    Structured payload:

    Proposed approach:
    Resume the asker with the focused repair prompt below, then make exactly one follow-up implementation pass.

    Cost of guessing wrong:
    If the asker repeats the same blind spot, this repair move is spent and the run settles failed when verification stays red.

    Failing check evidence:
    #{failing_check_evidence(data.verdict)}

    Focused repair prompt the asker will receive:
    #{repair_prompt}

    Return one concise rationale line, then a final sentinel on its own line:
    <<<VERDICT:APPROVE>>>
    or
    <<<VERDICT:REJECT>>>
    """
  end

  @spec semantic_gate_prompt(data(), String.t()) :: String.t()
  defp semantic_gate_prompt(data, diff) do
    """
    You are the cross-family semantic gate for a harness green verdict.

    The verification stack has passed. Your job is adversarial semantic review:
    decide whether the committed diff actually satisfies the task body and
    acceptance criteria, without accepting evasions like deleted tests, stubs,
    or solving only an adjacent problem.

    Implementer: #{data.item.agent}
    Commit: #{current_sha(data)}

    Task body:
    #{empty_placeholder(data.item.body)}

    Acceptance criteria:
    #{format_acceptance_criteria(data.item.acceptance_criteria)}

    Committed diff:
    #{diff}

    Return one concise rationale line, then a final sentinel on its own line:
    <<<VERDICT:APPROVE>>>
    or
    <<<VERDICT:REJECT>>>
    """
  end

  @spec semantic_repair_prompt(data()) :: String.t()
  defp semantic_repair_prompt(data) do
    rationale =
      case data.cross_agent_feedback do
        %{rationale: rationale} -> rationale
        _ -> "No rationale provided."
      end

    """
    harness semantic gate rejected your green verification attempt on task #{data.item.id} —
    repair attempt #{data.repair_attempts} of #{data.max_repair_attempts}.

    The verification checks passed, but the cross-family semantic reviewer did
    not approve the committed diff against the task contract. Repair the actual
    task semantics, not just the check stack. Leave your fixes in the working
    tree; harness will commit, verify, and run the semantic gate again.

    Reviewer rationale:
    #{rationale}

    Task body:
    #{empty_placeholder(data.item.body)}

    Acceptance criteria:
    #{format_acceptance_criteria(data.item.acceptance_criteria)}
    """
  end

  @spec committed_diff(data()) :: {:ok, String.t()} | {:error, term()}
  defp committed_diff(data) do
    args = [
      "show",
      "--stat",
      "--patch",
      "--find-renames",
      "--no-ext-diff",
      "--unified=#{@semantic_diff_context_lines}",
      "--format=fuller",
      current_sha(data)
    ]

    case Git.run(args, data.worktree.path) do
      {:ok, diff} -> {:ok, truncate_semantic_diff(diff)}
      {:error, reason} -> {:error, {:diff_unavailable, reason}}
    end
  end

  @spec truncate_semantic_diff(String.t()) :: String.t()
  defp truncate_semantic_diff(diff) when byte_size(diff) <= @semantic_diff_max_bytes, do: diff

  defp truncate_semantic_diff(diff) do
    head = binary_part(diff, 0, @semantic_diff_max_bytes)

    "[harness: showing the first #{@semantic_diff_max_bytes} of #{byte_size(diff)} bytes]\n" <>
      valid_utf8_head(head)
  end

  @spec valid_utf8_head(binary()) :: binary()
  defp valid_utf8_head(<<>>), do: <<>>

  defp valid_utf8_head(bin) do
    if String.valid?(bin),
      do: bin,
      else: valid_utf8_head(binary_part(bin, 0, byte_size(bin) - 1))
  end

  @spec empty_placeholder(String.t() | nil) :: String.t()
  defp empty_placeholder(nil), do: "(none)"
  defp empty_placeholder(""), do: "(none)"
  defp empty_placeholder(text), do: text

  @spec format_acceptance_criteria([String.t()]) :: String.t()
  defp format_acceptance_criteria([]), do: "(none)"

  defp format_acceptance_criteria(criteria), do: Enum.map_join(criteria, "\n", fn criterion -> "- #{criterion}" end)

  @spec add_cross_agent_feedback(
          String.t(),
          %{verdict: AuditReview.verdict(), rationale: String.t()} | nil
        ) ::
          String.t()
  defp add_cross_agent_feedback(prompt, nil), do: prompt

  defp add_cross_agent_feedback(prompt, %{verdict: verdict, rationale: rationale}) do
    action =
      case verdict do
        :approve ->
          "Commit to the proposed approach."

        :reject ->
          "Pivot away from the proposed approach and address the repeated failure from a different angle."

        :unclear ->
          "Treat the missing approval as a rejection and pivot before editing."
      end

    """
    Cross-agent grader verdict before this repair attempt: #{verdict |> Atom.to_string() |> String.upcase()}.
    Rationale: #{rationale}
    #{action}

    #{prompt}
    """
  end

  @spec cross_agent_rationale(String.t()) :: String.t()
  defp cross_agent_rationale(output) when is_binary(output) do
    rationale =
      output
      |> String.split("\n")
      |> Enum.reject(&String.contains?(&1, "<<<VERDICT:"))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> List.last()

    case rationale do
      nil -> "No rationale provided."
      rationale -> rationale
    end
  end

  @spec failing_check_evidence(Verdict.t()) :: String.t()
  defp failing_check_evidence(%Verdict{results: results}) do
    results
    |> Enum.filter(&(&1.status == :fail))
    |> Enum.map_join("\n\n", &format_check_evidence/1)
  end

  @spec format_check_evidence(CheckResult.t()) :: String.t()
  defp format_check_evidence(%CheckResult{} = result) do
    """
    check: #{result.name}
    status: #{check_status_line(result)}
    command: #{result.command}
    output:
    #{String.trim(result.output)}
    """
  end

  @spec check_status_line(CheckResult.t()) :: String.t()
  defp check_status_line(%CheckResult{kind: :exited, exit_status: status}), do: "exited #{status}"
  defp check_status_line(%CheckResult{kind: :timed_out}), do: "timed out"
  defp check_status_line(%CheckResult{kind: :not_launched}), do: "could not launch"

  @spec failed_check_signatures(Verdict.t()) :: MapSet.t(term())
  defp failed_check_signatures(%Verdict{results: results}) do
    results
    |> Enum.filter(&(&1.status == :fail))
    |> MapSet.new(&failed_check_signature/1)
  end

  @spec failed_check_signature(CheckResult.t()) :: term()
  defp failed_check_signature(%CheckResult{} = result) do
    {result.name, result.kind, result.exit_status, error_signature(result)}
  end

  @spec error_signature(CheckResult.t()) :: String.t()
  defp error_signature(%CheckResult{output: output}) do
    :sha256
    |> :crypto.hash(String.trim(output))
    |> Base.encode16(case: :lower)
  end

  @spec repeated_failure?(MapSet.t(term()), MapSet.t(term())) :: boolean()
  defp repeated_failure?(previous, current) do
    not MapSet.disjoint?(previous, current)
  end

  @spec cross_agent_repair_enabled?(data()) :: boolean()
  defp cross_agent_repair_enabled?(data) do
    Keyword.get(data.cross_agent_repair, :enabled, false)
  end

  # A per-dispatch `enabled: true | false` opt forces the gate on/off for one
  # run regardless of landing policy (Task 123 AC2). Absent / `:auto` defers to
  # the project-level `semantic_gate` mode, which decouples gate-enablement from
  # auto-land so a manual-landing project (e.g. harness's own dogfooding) can
  # opt the AC-aware check on.
  @spec semantic_gate_enabled?(data()) :: boolean()
  defp semantic_gate_enabled?(data) do
    case Keyword.get(data.semantic_gate, :enabled, :auto) do
      true -> true
      :auto -> project_semantic_gate_enabled?(data.project)
      _ -> false
    end
  end

  @spec project_semantic_gate_enabled?(Project.t()) :: boolean()
  defp project_semantic_gate_enabled?(%Project{semantic_gate: :always}), do: true
  defp project_semantic_gate_enabled?(%Project{semantic_gate: :off}), do: false

  defp project_semantic_gate_enabled?(%Project{semantic_gate: :auto_land_only, landing_policy: policy}),
    do: policy == :auto

  @spec current_sha(data()) :: String.t()
  defp current_sha(%{worktree: %Worktree{path: path, base_sha: fallback}}) do
    case Git.run(["rev-parse", "HEAD"], path) do
      {:ok, sha} -> non_empty_sha(String.trim(sha), fallback)
      {:error, _reason} -> fallback
    end
  end

  @spec non_empty_sha(String.t(), String.t()) :: String.t()
  defp non_empty_sha("", fallback), do: fallback
  defp non_empty_sha(sha, _fallback), do: sha

  # The message stamped on the agent's delivery commit — identifies the run and
  # the rmap task it served, so the commit is legible in `git log` after the
  # worktree it came from is gone. Each repair attempt commits separately, so
  # the branch history reads as a sequence of attempts.
  @spec commit_message(data()) :: String.t()
  defp commit_message(%{repair_attempts: 0} = data) do
    "harness: agent delivery — task #{data.item.id} #{data.item.title} (run #{data.run_id})"
  end

  defp commit_message(data) do
    "harness: repair attempt #{data.repair_attempts} — task #{data.item.id} #{data.item.title} (run #{data.run_id})"
  end

  @spec worktree_opts(data()) :: keyword()
  defp worktree_opts(data) do
    [id: data.run_id]
    |> put_opt(:base_dir, data.base_dir)
    |> put_opt(:base_ref, data.base_ref)
  end

  @spec driver_opts(data(), pid()) :: keyword()
  defp driver_opts(data, parent) do
    [
      on_spawn: fn run -> send(parent, {:run_handle, run}) end,
      on_output: fn chunk -> send(parent, {:transcript_chunk, chunk}) end
    ]
    |> put_opt(:total_timeout, data.total_timeout)
    |> put_opt(:idle_timeout, data.idle_timeout)
    |> put_opt(:progress_timeout, data.progress_timeout)
  end

  @spec verification_opts(data()) :: keyword()
  defp verification_opts(data) do
    opts =
      if data.checks do
        [checks: data.checks]
      else
        [check_stacks: data.project.check_stacks]
      end

    opts
    |> put_opt(:timeout, data.verification_timeout)
    |> put_opt(:base_ref, data.worktree && data.worktree.base_sha)
  end

  @spec commit_worktree(Worktree.t(), String.t()) ::
          {:ok, :committed | :no_changes, non_neg_integer()} | {:error, Worktree.error()}
  defp commit_worktree(%Worktree{} = worktree, message) do
    with {:ok, diff_size} <- Worktree.diff_size(worktree),
         {:ok, status} <- Worktree.commit(worktree, message) do
      {:ok, status, diff_size}
    end
  end

  @spec first_attempt_failed_check_count(data(), Verdict.t()) :: non_neg_integer()
  defp first_attempt_failed_check_count(%{repair_attempts: 0}, %Verdict{results: results}) do
    Enum.count(results, &(&1.status == :fail))
  end

  defp first_attempt_failed_check_count(data, _verdict), do: data.first_attempt_failed_check_count

  @spec put_opt(keyword(), atom(), term()) :: keyword()
  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  @spec cross_agent_repair_opts(keyword()) :: keyword()
  defp cross_agent_repair_opts(opts) do
    opts
    |> Keyword.get(:cross_agent_repair, Application.get_env(:harness, :cross_agent_repair, []))
    |> normalize_cross_agent_repair_opts()
  end

  @spec semantic_gate_opts(keyword()) :: keyword()
  defp semantic_gate_opts(opts) do
    opts
    |> Keyword.get(:semantic_gate, Application.get_env(:harness, :semantic_gate, enabled: :auto))
    |> normalize_cross_agent_repair_opts()
  end

  @spec normalize_cross_agent_repair_opts(nil | keyword() | map()) :: keyword()
  defp normalize_cross_agent_repair_opts(nil), do: []
  defp normalize_cross_agent_repair_opts(opts) when is_list(opts), do: opts
  defp normalize_cross_agent_repair_opts(opts) when is_map(opts), do: Map.to_list(opts)

  @spec checkout_snapshot_for_run(data()) :: String.t() | nil
  defp checkout_snapshot_for_run(data) do
    if AgentAdapter.supports?(data.adapter, :worktree_isolation) do
      nil
    else
      checkout_snapshot(Project.repo_path(data.project))
    end
  end

  @spec checkout_snapshot(String.t()) :: String.t() | nil
  defp checkout_snapshot(repo) when is_binary(repo) do
    case Reflex.checkout_snapshot(repo) do
      {:ok, snapshot} ->
        snapshot

      {:error, reason} ->
        Logger.warning("harness run: checkout snapshot failed for #{repo}: #{inspect(reason)}")
        nil
    end
  end

  @spec checkout_pollution_reason(data()) :: Result.reason() | nil
  defp checkout_pollution_reason(data) do
    opts = [pollution_allowlist: data.pollution_allowlist]

    Reflex.checkout_pollution_reason(Project.repo_path(data.project), data.checkout_snapshot, opts)
  end

  @spec resolve_pollution_allowlist(Project.t(), keyword()) :: [String.t()]
  defp resolve_pollution_allowlist(project, opts) do
    case Keyword.get(opts, :pollution_allowlist) do
      allowlist when is_list(allowlist) ->
        allowlist

      _ ->
        case project do
          %Project{pollution_allowlist: allowlist} when is_list(allowlist) -> allowlist
          _ -> Isolation.pollution_allowlist([])
        end
    end
  end

  @spec configured(atom(), term()) :: term()
  defp configured(key, default) do
    :harness |> Application.get_env(:run, []) |> Keyword.get(key, default)
  end

  # Resolves the adapter module back to its `Parser.agent_kind` atom for the
  # transcript parser. Returns `nil` for unregistered adapters (test doubles,
  # ad-hoc invocations) so the run still functions — the parsed-event surface
  # stays empty in that case and only `?raw=1` shows anything in the dashboard.
  @spec agent_kind_for(module()) :: Parser.agent_kind() | nil
  defp agent_kind_for(adapter) do
    case AgentRegistry.agent_for_module(adapter) do
      {:ok, kind} -> kind
      {:error, _} -> nil
    end
  end

  @spec init_parser_state(module()) :: Parser.parser_state() | nil
  defp init_parser_state(adapter) do
    case agent_kind_for(adapter) do
      nil -> nil
      kind -> Parser.init_state(kind)
    end
  end

  # Feeds a chunk through the parser when the executing adapter resolved to a
  # known `agent_kind`; otherwise threads existing state untouched with an empty
  # delta. The cap-and-evict trim AND the broadcast delta both come from
  # `Transcript.append_chunk/4`'s three-tuple return so the producer never has
  # to recompute either.
  @spec parse_chunk(data(), iodata()) ::
          {[Parser.event()], [Parser.event()], Parser.parser_state() | nil}
  defp parse_chunk(%{agent_kind: nil} = data, _chunk) do
    {data.transcript_events, [], data.transcript_parser_state}
  end

  defp parse_chunk(%{agent_kind: kind, transcript_events: events, transcript_parser_state: state}, chunk) do
    Transcript.append_chunk(events, kind, state, chunk)
  end

  # Flushes any trailing partial-line bytes the per-agent parser buffered when
  # the agent's Port closed (a complete JSON object/event without a final
  # newline would otherwise never surface in the parsed-event view). Mirrors
  # the per-chunk path: trim via the shared helper, and broadcast the drained
  # delta on a fresh seq so a live subscriber sees the last event too.
  # No-op for unregistered adapters (agent_kind: nil).
  @spec finalize_transcript(data()) :: data()
  defp finalize_transcript(%{agent_kind: nil} = data), do: data

  defp finalize_transcript(%{agent_kind: kind, transcript_events: events, transcript_parser_state: state} = data) do
    {new_events, delta, new_parser_state} = Transcript.finalize(events, kind, state)

    if delta == [] do
      %{data | transcript_events: new_events, transcript_parser_state: new_parser_state}
    else
      new_seq = data.transcript_seq + 1
      Transcript.broadcast_events(data.run_id, new_seq, delta)

      %{
        data
        | transcript_events: new_events,
          transcript_parser_state: new_parser_state,
          transcript_seq: new_seq
      }
    end
  end
end
