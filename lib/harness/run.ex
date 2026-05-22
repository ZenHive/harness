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
  one is running, then settle `failed`. Crash isolation is structural — each run
  is a `:temporary` child of `Harness.Run.Supervisor` (a `:one_for_one`
  DynamicSupervisor), so one run crashing never touches a sibling.

  ## Observability

  `status/1` returns a `Harness.Run.Status` snapshot at any point while the run
  is in flight or lingering in a terminal state.
  """

  @behaviour :gen_statem

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Driver
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Outcome
  alias Harness.AgentAdapter.Run, as: AgentRun
  alias Harness.Roadmap.Item
  alias Harness.Run.RepairPrompt
  alias Harness.Run.Result
  alias Harness.Run.Status
  alias Harness.Verification
  alias Harness.Verification.Check
  alias Harness.Verification.Verdict
  alias Harness.Worktree

  require Logger

  @registry Harness.Run.Registry
  @task_supervisor Harness.Run.TaskSupervisor

  @default_lifetime_timeout 5_400_000
  @default_terminal_linger 5_000
  @default_max_repair_attempts 2

  @typedoc "A lifecycle state."
  @type state :: :dispatched | :running | :committing | :verifying | :done | :failed

  @typedoc "A run handle: a run id, or the gen_statem pid directly."
  @type run :: String.t() | pid()

  @typedoc false
  @type init_arg :: {Item.t(), String.t(), module(), keyword()}

  @typep data :: %{
           run_id: String.t(),
           item: Item.t(),
           repo: String.t(),
           adapter: module(),
           subscriber: pid() | nil,
           total_timeout: timeout() | nil,
           idle_timeout: timeout() | nil,
           lifetime_timeout: pos_integer(),
           terminal_linger: non_neg_integer(),
           max_repair_attempts: non_neg_integer(),
           repair_attempts: non_neg_integer(),
           checks: [Check.t()] | nil,
           verification_timeout: timeout() | nil,
           base_dir: String.t() | nil,
           base_ref: String.t() | nil,
           adapter_opts: keyword(),
           env: %{optional(String.t()) => String.t() | false},
           worktree: Worktree.t() | nil,
           agent_run: AgentRun.t() | nil,
           agent_outcome: Outcome.t() | nil,
           verdict: Verdict.t() | nil,
           task: Task.t() | nil,
           cancel_requested: {Result.reason(), :gen_statem.from() | nil} | nil,
           reason: Result.reason() | nil,
           result: Result.t() | nil
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

  @doc """
  Starts a run lifecycle for `item` against `repo`, driven by `adapter`.

  Normally started through `Harness.Run.Supervisor.start_run/4`, which generates
  the run id and supervises the process. `opts` must carry `:run_id`; see that
  function for the full option set.
  """
  @spec start_link(init_arg()) :: :gen_statem.start_ret()
  def start_link({%Item{}, repo, adapter, opts} = arg) when is_binary(repo) and is_atom(adapter) and is_list(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    :gen_statem.start_link({:via, Registry, {@registry, run_id}}, __MODULE__, arg, [])
  end

  @doc """
  Returns a `Harness.Run.Status` snapshot of the run, or `{:error, :not_found}`.

  Accepts a run id or the gen_statem pid. A run that has already stopped is no
  longer registered and reports `{:error, :not_found}`.
  """
  @spec status(run()) :: {:ok, Status.t()} | {:error, :not_found}
  def status(run) do
    with {:ok, pid} <- resolve(run) do
      {:ok, :gen_statem.call(pid, :status)}
    end
  catch
    :exit, _reason -> {:error, :not_found}
  end

  @doc """
  Cancels an in-flight run: kills the agent and settles the run `failed`.

  Accepts a run id or pid. Idempotent — cancelling an already-settled or unknown
  run is a no-op that still returns `:ok`.
  """
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

  @impl :gen_statem
  @spec callback_mode() :: [:state_functions | :state_enter]
  def callback_mode, do: [:state_functions, :state_enter]

  @impl :gen_statem
  @spec init(init_arg()) :: {:ok, :dispatched, data(), [:gen_statem.action()]}
  def init({item, repo, adapter, opts}) do
    data = %{
      run_id: Keyword.fetch!(opts, :run_id),
      item: item,
      repo: repo,
      adapter: adapter,
      subscriber: Keyword.get(opts, :subscriber),
      total_timeout: Keyword.get(opts, :total_timeout),
      idle_timeout: Keyword.get(opts, :idle_timeout),
      lifetime_timeout: Keyword.get(opts, :lifetime_timeout) || configured(:lifetime_timeout, @default_lifetime_timeout),
      terminal_linger: Keyword.get(opts, :terminal_linger) || configured(:terminal_linger, @default_terminal_linger),
      max_repair_attempts:
        Keyword.get(opts, :max_repair_attempts) ||
          configured(:max_repair_attempts, @default_max_repair_attempts),
      repair_attempts: 0,
      checks: Keyword.get(opts, :checks),
      verification_timeout: Keyword.get(opts, :verification_timeout),
      base_dir: Keyword.get(opts, :base_dir),
      base_ref: Keyword.get(opts, :base_ref),
      adapter_opts: Keyword.get(opts, :adapter_opts, []),
      env: Keyword.get(opts, :env, %{}),
      worktree: nil,
      agent_run: nil,
      agent_outcome: nil,
      verdict: nil,
      task: nil,
      cancel_requested: nil,
      reason: nil,
      result: nil
    }

    {:ok, :dispatched, data, [{{:timeout, :lifetime}, data.lifetime_timeout, :lifetime}]}
  end

  # ── State: dispatched — carve the isolated worktree ───────────────────────

  @doc false
  @spec dispatched(event(), term(), data()) :: handler_result()
  def dispatched(:enter, _old_state, data) do
    task = start_task(fn -> Worktree.create(data.repo, worktree_opts(data)) end)
    {:keep_state, %{data | task: task}}
  end

  def dispatched(:info, {ref, {:ok, %Worktree{} = worktree}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    {:next_state, :running, %{data | task: nil, worktree: worktree}}
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
    parent = self()
    invocation = build_invocation(data)
    task = start_task(fn -> Driver.run(data.adapter, invocation, driver_opts(data, parent)) end)
    {:keep_state, %{data | task: task, agent_run: nil, agent_outcome: nil}}
  end

  def running(:info, {:run_handle, %AgentRun{} = run}, data) do
    data = %{data | agent_run: run}

    case data.cancel_requested do
      nil -> {:keep_state, data}
      {reason, from} -> do_cancel(data, reason, from)
    end
  end

  def running(:info, {ref, {:ok, %Outcome{} = outcome}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    data = %{data | task: nil, agent_outcome: outcome}

    case data.cancel_requested do
      nil -> {:next_state, :committing, data}
      {reason, from} -> do_cancel(data, reason, from)
    end
  end

  def running(:info, {ref, {:error, reason}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    fail(%{data | task: nil}, {:agent_spawn_failed, reason})
  end

  def running(:info, {:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = data) when reason != :normal do
    fail(%{data | task: nil}, {:driver_crashed, reason})
  end

  def running(event_type, event_content, data) do
    handle_common(event_type, event_content, :running, data)
  end

  # ── State: committing — capture the agent's work on the run branch ────────

  @doc false
  @spec committing(event(), term(), data()) :: handler_result()
  def committing(:enter, _old_state, data) do
    worktree = data.worktree
    message = commit_message(data)
    task = start_task(fn -> Worktree.commit(worktree, message) end)
    {:keep_state, %{data | task: task}}
  end

  def committing(:info, {ref, {:ok, :committed}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    {:next_state, :verifying, %{data | task: nil}}
  end

  def committing(:info, {ref, {:ok, :no_changes}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    fail(%{data | task: nil}, :no_changes)
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
    worktree = data.worktree
    task = start_task(fn -> Verification.run(worktree.path, verification_opts(data)) end)
    {:keep_state, %{data | task: task}}
  end

  def verifying(:info, {ref, {:ok, %Verdict{} = verdict}}, %{task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    data = %{data | task: nil, verdict: verdict}

    cond do
      Verdict.passed?(verdict) ->
        {:next_state, :done, %{data | reason: :passed}}

      repairable?(data) ->
        # Loop back to `running`: the same agent is resumed with the failing
        # checks fed back. `build_invocation/1` reads the incremented count.
        {:next_state, :running, %{data | repair_attempts: data.repair_attempts + 1}}

      true ->
        {:next_state, :failed, %{data | reason: :verification_red}}
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

  defp handle_common({:timeout, :lifetime}, :lifetime, :running, %{agent_run: nil, cancel_requested: nil} = data) do
    {:keep_state, %{data | cancel_requested: {:timed_out, nil}}}
  end

  defp handle_common({:timeout, :lifetime}, :lifetime, :running, %{agent_run: nil}) do
    # A cancel is already deferred and will settle the run once the agent
    # handle arrives — don't clobber its pending reply target with the
    # timeout's.
    :keep_state_and_data
  end

  defp handle_common({:timeout, :lifetime}, :lifetime, _state, data) do
    do_cancel(data, :timed_out, nil)
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
    data = %{data | task: nil, agent_run: nil, cancel_requested: nil, reason: reason}
    actions = if from, do: [{:reply, from, :ok}], else: []
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

  # Builds the final result, delivers it to the subscriber, then tears the
  # worktree down. The subscriber is notified *before* teardown so the result is
  # delivered even if teardown fails.
  @spec settle(data(), Result.state()) :: data()
  defp settle(data, terminal_state) do
    result = build_result(data, terminal_state)
    notify_subscriber(data.subscriber, data.run_id, result)
    finish_worktree(data.worktree, terminal_state)
    %{data | result: result}
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
      repair_attempts: data.repair_attempts
    }
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
      state: state,
      worktree_path: data.worktree && data.worktree.path,
      agent_os_pid: data.agent_run && data.agent_run.os_pid,
      agent_kind: data.agent_outcome && data.agent_outcome.kind,
      verdict_status: data.verdict && data.verdict.status,
      repair_attempts: data.repair_attempts
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

  defp build_invocation(%{verdict: %Verdict{} = verdict} = data) do
    prompt = RepairPrompt.build(data.item, verdict, data.repair_attempts, data.max_repair_attempts)
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
      adapter_opts: data.adapter_opts,
      env: data.env
    }
  end

  # Whether a red verdict should trigger another repair attempt: the cap is not
  # yet spent, and the adapter can resume its session — the channel the failing
  # checks are fed back through.
  @spec repairable?(data()) :: boolean()
  defp repairable?(data) do
    data.repair_attempts < data.max_repair_attempts and
      AgentAdapter.supports?(data.adapter, :session_resume)
  end

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
    [on_spawn: fn run -> send(parent, {:run_handle, run}) end]
    |> put_opt(:total_timeout, data.total_timeout)
    |> put_opt(:idle_timeout, data.idle_timeout)
  end

  @spec verification_opts(data()) :: keyword()
  defp verification_opts(data) do
    []
    |> put_opt(:checks, data.checks)
    |> put_opt(:timeout, data.verification_timeout)
  end

  @spec put_opt(keyword(), atom(), term()) :: keyword()
  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  @spec configured(atom(), term()) :: term()
  defp configured(key, default) do
    :harness |> Application.get_env(:run, []) |> Keyword.get(key, default)
  end
end
