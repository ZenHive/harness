defmodule Harness.AgentAdapter.Driver do
  @moduledoc """
  Drives one agent run from spawn to completion under two timeout guards.

  `run/3` spawns an adapter via `Harness.AgentAdapter.invoke/2`, then loops on
  the port's messages — feeding each through the adapter's
  `c:Harness.AgentAdapter.classify_message/2`, accumulating raw output, and
  enforcing termination. It is adapter-agnostic: every adapter is driven the
  same way.

  ## Two deadlines

    * **Total-run budget** — an absolute deadline from the run's spawn time. A
      run is killed when it passes, however much output it is still producing.
    * **Idle window** — an absolute deadline reset on every output chunk. A run
      that emits nothing for the configured window is killed even though the
      total budget has not been spent.

  Both are necessary: the total budget caps a runaway agent that keeps working,
  the idle window catches one that has wedged (blocked on a prompt, deadlocked)
  while the total budget still has room. Termination is derived from the port
  closing or a deadline firing — never from the exit code (`Outcome.kind` is the
  signal; `exit_status` is advisory).

  ## Configuration

  Under the `:harness, :run` application key — both keys optional, defaults in
  code:

    * `:total_timeout` — total-run budget in milliseconds. Default `1_800_000`
      (30 minutes).
    * `:idle_timeout` — idle window in milliseconds. Default `300_000`
      (5 minutes).

  Per-call `:total_timeout` / `:idle_timeout` options override the config.

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

  @default_total_timeout 1_800_000
  @default_idle_timeout 300_000

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
          "Keyword list. :total_timeout / :idle_timeout (ms overrides). :on_spawn (1-arity hook called with the Run handle the moment the agent spawns — used by Harness.Run to capture the handle for cancellation). :on_output (1-arity hook called with each iodata chunk — used by Harness.Run to fan transcripts to the dashboard PubSub topic). Hook exceptions are swallowed."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %Harness.AgentAdapter.Outcome{}} for any spawned run (including timeouts / mid-run port errors — kind: :exited | {:timed_out, :idle | :total} | {:error, reason}). {:error, reason} only when nothing spawned (build_command/1 failed, executable missing)."
    }
  )

  @spec run(module(), Invocation.t(), keyword()) :: {:ok, Outcome.t()} | {:error, term()}
  def run(adapter, %Invocation{} = invocation, opts \\ []) do
    total = Keyword.get(opts, :total_timeout) || configured_total_timeout()
    idle = Keyword.get(opts, :idle_timeout) || configured_idle_timeout()
    on_output = Keyword.get(opts, :on_output)

    case AgentAdapter.invoke(adapter, invocation) do
      {:ok, %Run{} = run} ->
        notify_spawn(Keyword.get(opts, :on_spawn), run)
        {:ok, drive(adapter, run, total, idle, on_output)}

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
  @spec drive(module(), Run.t(), non_neg_integer(), non_neg_integer(), (iodata() -> any()) | nil) :: Outcome.t()
  defp drive(adapter, run, total, idle, on_output) do
    started_ms = System.convert_time_unit(run.started_at, :native, :millisecond)
    loop(adapter, run, started_ms + total, idle, idle_deadline(idle), [], on_output)
  end

  # Drains the port until the run terminates or a deadline passes. `after` waits
  # only until the nearer deadline; an output chunk resets the idle deadline.
  # The pre-`receive` guard closes the starvation gap — a flooding agent that
  # keeps the mailbox non-empty would otherwise let `receive` always match a
  # message and never reach the `after` clause, evading both deadlines. The
  # `on_output` hook (when set) fans each chunk to the dashboard transcript
  # stream — invoked inline so a subscriber sees output at the same cadence the
  # accumulator does.
  @spec loop(module(), Run.t(), integer(), non_neg_integer(), integer(), iodata(), (iodata() -> any()) | nil) ::
          Outcome.t()
  defp loop(adapter, run, total_deadline, idle, idle_deadline, acc, on_output) do
    wait = min(remaining(total_deadline), remaining(idle_deadline))

    if wait == 0 do
      expire(adapter, run, acc, total_deadline)
    else
      receive do
        message ->
          case adapter.classify_message(message, run) do
            {:output, data, next_run} ->
              notify_output(on_output, data)
              loop(adapter, next_run, total_deadline, idle, idle_deadline(idle), [acc, data], on_output)

            {:terminated, next_run, status} ->
              outcome(next_run, acc, status, :exited)

            {:error, reason, next_run} ->
              adapter.terminate(next_run)
              outcome(next_run, acc, nil, {:error, reason})

            :ignore ->
              loop(adapter, run, total_deadline, idle, idle_deadline, acc, on_output)
          end
      after
        wait ->
          expire(adapter, run, acc, total_deadline)
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

  # Kills a run that hit a deadline and reports which deadline fired.
  @spec expire(module(), Run.t(), iodata(), integer()) :: Outcome.t()
  defp expire(adapter, run, acc, total_deadline) do
    adapter.terminate(run)
    outcome(run, acc, nil, timed_out_kind(total_deadline))
  end

  # A fresh idle deadline, `idle` ms from now.
  @spec idle_deadline(non_neg_integer()) :: integer()
  defp idle_deadline(idle), do: System.monotonic_time(:millisecond) + idle

  # Milliseconds left until `deadline`, floored at 0 so `receive`'s `after`
  # never sees a negative value.
  @spec remaining(integer()) :: non_neg_integer()
  defp remaining(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))

  # Which deadline fired: the total budget wins ties, so it is checked first.
  @spec timed_out_kind(integer()) :: {:timed_out, :idle | :total}
  defp timed_out_kind(total_deadline) do
    if System.monotonic_time(:millisecond) >= total_deadline,
      do: {:timed_out, :total},
      else: {:timed_out, :idle}
  end

  @spec outcome(Run.t(), iodata(), integer() | nil, Outcome.kind()) :: Outcome.t()
  defp outcome(run, acc, exit_status, kind) do
    %Outcome{run: run, output: IO.iodata_to_binary(acc), exit_status: exit_status, kind: kind}
  end

  @spec configured_total_timeout() :: non_neg_integer()
  defp configured_total_timeout do
    :harness |> Application.get_env(:run, []) |> Keyword.get(:total_timeout, @default_total_timeout)
  end

  @spec configured_idle_timeout() :: non_neg_integer()
  defp configured_idle_timeout do
    :harness |> Application.get_env(:run, []) |> Keyword.get(:idle_timeout, @default_idle_timeout)
  end
end
