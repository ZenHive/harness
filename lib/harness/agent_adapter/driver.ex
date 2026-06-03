defmodule Harness.AgentAdapter.Driver do
  @moduledoc """
  Drives one agent run from spawn to completion under the deterministic reflex
  watchdog.

  `run/3` spawns an adapter via `Harness.AgentAdapter.invoke/2`, then loops on
  the port's messages — feeding each through the adapter's
  `c:Harness.AgentAdapter.classify_message/2`, accumulating raw output, and
  enforcing termination. It is adapter-agnostic: every adapter is driven the
  same way.

  ## Deadlines

    * **Total-run budget** — an absolute deadline from the run's spawn time. A
      run is killed when it passes, however much output it is still producing.
    * **Idle window** — an absolute deadline reset on every output chunk. A run
      that emits nothing for the configured window is killed even though the
      total budget has not been spent.
    * **Progress window** — an absolute deadline reset only by an edit or a new
      tool call. A run that keeps printing text while making no mechanical
      progress is killed.

  Termination is derived from the port closing or a reflex guard firing — never
  from the exit code (`Outcome.kind` is the signal; `exit_status` is advisory).

  ## Configuration

  Under the `:harness, :run` application key — both keys optional, defaults in
  code:

    * `:total_timeout` — total-run budget in milliseconds. Default `1_800_000`
      (30 minutes).
    * `:idle_timeout` — idle window in milliseconds. Default `300_000`
      (5 minutes).
    * `:progress_timeout` — progress-stall window in milliseconds. Default
      `300_000` (5 minutes).

  Per-call timeout options override the config.

  ## Concurrency

  `run/3` is a plain blocking function — it traps no exits, links and monitors
  nothing, and its only inputs are the port messages delivered to the calling
  process. The supervised run lifecycle (a `gen_statem`) wraps it, e.g. in a
  monitored `Task`; the driver itself stays a pure receive loop. Because `run/3`
  blocks until the run ends, a wrapping process that needs to cancel the agent
  cannot otherwise reach the `Harness.AgentAdapter.Run` handle — the `:on_spawn`
  option hands it that handle the moment the agent spawns.
  """

  use Descripex, namespace: "/agent_adapter/driver"

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Outcome
  alias Harness.AgentAdapter.Run
  alias Harness.Run.Reflex

  @default_total_timeout 1_800_000
  @default_idle_timeout 300_000
  @default_progress_timeout 300_000

  api(:run, "Spawn the adapter for an invocation and drive it to completion under total + idle deadlines.",
    params: [
      adapter: [
        kind: :value,
        description:
          "Adapter module implementing Harness.AgentAdapter (e.g. Harness.AgentAdapter.Claude). The caller supplies the module atom."
      ],
      invocation: [
        kind: :value,
        description:
          "Harness.AgentAdapter.Invocation struct. Caller-constructed: cwd, prompt, task_id, env scrub map, adapter_opts, model."
      ],
      opts: [
        kind: :value,
        default: [],
        description:
          "Keyword list. :total_timeout / :idle_timeout / :progress_timeout (ms overrides). :on_spawn (1-arity hook called with the Run handle the moment the agent spawns — used by Harness.Run to capture the handle for cancellation). :on_output (1-arity hook called with each iodata chunk — used by Harness.Run to fan transcripts to the dashboard PubSub topic). Hook exceptions are swallowed."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %Harness.AgentAdapter.Outcome{}} for any spawned run (including timeouts / mid-run port errors — kind: :exited | {:timed_out, :idle | :total} | {:reflex_halted, reason} | {:error, reason}). {:error, reason} only when nothing spawned (build_command/1 failed, executable missing)."
    }
  )

  @spec run(module(), Invocation.t(), keyword()) :: {:ok, Outcome.t()} | {:error, term()}
  def run(adapter, %Invocation{} = invocation, opts \\ []) do
    {total, idle, progress} = resolve_timeouts(opts)
    on_output = Keyword.get(opts, :on_output)

    case AgentAdapter.invoke(adapter, invocation) do
      {:ok, %Run{} = run} ->
        notify_spawn(Keyword.get(opts, :on_spawn), run)
        {:ok, drive(adapter, run, invocation, total, idle, progress, on_output)}

      {:error, _reason} = error ->
        error
    end
  end

  # Runs the optional :on_spawn hook with the freshly spawned run handle. The
  # hook is the only way a caller in another process — the run-lifecycle
  # gen_statem — can capture the Run before drive/4 blocks, and so the only way
  # it can later cancel the agent. Wrapped so a throwing hook cannot abort the
  # run and orphan the just-spawned OS process.
  @spec notify_spawn((Run.t() -> any()) | nil, Run.t()) :: :ok
  defp notify_spawn(nil, _run), do: :ok

  defp notify_spawn(hook, run) when is_function(hook, 1) do
    hook.(run)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _value -> :ok
  end

  # Seeds both deadlines and enters the receive loop. The total deadline is
  # anchored to the run's spawn time so the budget covers the whole run.
  @spec drive(
          module(),
          Run.t(),
          Invocation.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer() | nil,
          (iodata() -> any()) | nil
        ) :: Outcome.t()
  defp drive(adapter, run, invocation, total, idle, progress, on_output) do
    reflex =
      Reflex.new(run, invocation,
        total_timeout: total,
        idle_timeout: idle,
        progress_timeout: progress,
        worktree_path: invocation.cwd
      )

    loop(adapter, run, reflex, [], on_output)
  end

  # Drains the port until the run terminates or a deadline passes. `after` waits
  # only until the nearer deadline; an output chunk resets the idle deadline.
  # The pre-`receive` guard closes the starvation gap — a flooding agent that
  # keeps the mailbox non-empty would otherwise let `receive` always match a
  # message and never reach the `after` clause, evading both deadlines. The
  # `on_output` hook (when set) fans each chunk to the dashboard transcript
  # stream — invoked inline so a subscriber sees output at the same cadence the
  # accumulator does.
  @spec loop(module(), Run.t(), Reflex.t(), iodata(), (iodata() -> any()) | nil) :: Outcome.t()
  defp loop(adapter, run, reflex, acc, on_output) do
    case Reflex.expired(reflex) do
      {:halt, kind, _reflex} ->
        expire(adapter, run, acc, kind)

      {:cont, reflex} ->
        receive_next(adapter, run, reflex, acc, on_output, Reflex.wait(reflex))
    end
  end

  @spec receive_next(module(), Run.t(), Reflex.t(), iodata(), (iodata() -> any()) | nil, non_neg_integer()) ::
          Outcome.t()
  defp receive_next(adapter, run, reflex, acc, on_output, wait) do
    receive do
      message ->
        case adapter.classify_message(message, run) do
          {:output, data, next_run} ->
            notify_output(on_output, data)
            acc = [acc, data]

            case Reflex.on_output(reflex, data) do
              {:cont, next_reflex} -> loop(adapter, next_run, next_reflex, acc, on_output)
              {:halt, kind, _next_reflex} -> expire(adapter, next_run, acc, kind)
            end

          {:terminated, next_run, status} ->
            outcome(next_run, acc, status, :exited)

          {:error, reason, next_run} ->
            adapter.terminate(next_run)
            outcome(next_run, acc, nil, {:error, reason})

          :ignore ->
            loop(adapter, run, reflex, acc, on_output)
        end
    after
      wait ->
        case Reflex.expired(reflex) do
          {:halt, kind, _reflex} -> expire(adapter, run, acc, kind)
          {:cont, next_reflex} -> loop(adapter, run, next_reflex, acc, on_output)
        end
    end
  end

  # Fans one output chunk to the optional :on_output hook. Wrapped so a
  # throwing or exiting hook never aborts the driver loop — the agent run must
  # finish even if the transcript pane is misconfigured.
  @spec notify_output((iodata() -> any()) | nil, iodata()) :: :ok
  defp notify_output(nil, _data), do: :ok

  defp notify_output(hook, data) when is_function(hook, 1) do
    hook.(data)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _value -> :ok
  end

  # Kills a run that tripped a reflex guard and reports which guard fired.
  @spec expire(module(), Run.t(), iodata(), Outcome.kind()) :: Outcome.t()
  defp expire(adapter, run, acc, kind) do
    adapter.terminate(run)
    outcome(run, acc, nil, kind)
  end

  @spec outcome(Run.t(), iodata(), integer() | nil, Outcome.kind()) :: Outcome.t()
  defp outcome(run, acc, exit_status, kind) do
    %Outcome{run: run, output: IO.iodata_to_binary(acc), exit_status: exit_status, kind: kind}
  end

  # Resolves the three reflex deadlines in one pass: per-call opts override the
  # `:harness, :run` config, which falls back to the module defaults. The config
  # is read once per run rather than once per timeout.
  @spec resolve_timeouts(keyword()) :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  defp resolve_timeouts(opts) do
    config = Application.get_env(:harness, :run, [])

    {
      Keyword.get(opts, :total_timeout) || Keyword.get(config, :total_timeout, @default_total_timeout),
      Keyword.get(opts, :idle_timeout) || Keyword.get(config, :idle_timeout, @default_idle_timeout),
      Keyword.get(opts, :progress_timeout) || Keyword.get(config, :progress_timeout, @default_progress_timeout)
    }
  end
end
