defmodule Harness.AgentAdapter do
  @moduledoc """
  The contract every headless coding-agent adapter implements.

  An adapter is deliberately thin: it builds an agent's headless command line,
  spawns it over an OTP port, classifies the port's messages as raw output /
  termination / failure, and can kill an in-flight run. It does **not** parse or
  normalize the agent's output — harness passes raw transcripts through
  untouched (the consumer is an AI that reads them natively) and derives run
  success from its own verification stack, never from the agent's exit code or
  self-reported result.

  ## Implementing an adapter

  An adapter `use`s `Harness.AgentAdapter` (which declares the `@behaviour`) and
  implements the two required callbacks; `classify_message/2` and `terminate/1`
  have defaults (universal port classification and kill) and need only be
  overridden for agent-specific logic:

      defmodule MyAgent.Adapter do
        use Harness.AgentAdapter
        alias Harness.AgentAdapter.Capabilities
        alias Harness.AgentAdapter.Invocation

        @impl true
        def capabilities, do: %Capabilities{session_resume: true}

        @impl true
        def build_command(%Invocation{} = invocation),
          do: {:ok, {"my-agent", ["-p", invocation.prompt], Map.to_list(invocation.env)}}
      end

  Harness spawns the adapter with `invoke/2` — there is no per-adapter
  invocation boilerplate.

  ## Run lifecycle

  `invoke/2` builds the command via the adapter's `c:build_command/1` and spawns
  the agent, returning a `Harness.AgentAdapter.Run`. The process that calls
  `invoke/2` becomes the port's connected process, so every subsequent port
  message is delivered to *it* — that process feeds each message through the
  adapter's `c:classify_message/2`, which is how raw output is captured and
  termination detected. A run ends when `classify_message/2` returns
  `:terminated` (the agent process closed) or `:error` (the port itself failed).
  `Harness.AgentAdapter.Driver` is the generic implementation of that drive
  loop — it adds raw-output accumulation and the total-run / idle timeout
  guards on top of `invoke/2` + `c:classify_message/2`.

  ## Deliberate deferrals

    * **Session-token extraction (resolved).** Resuming needs no dedicated
      token-extraction callback. The Claude Code adapter resumes the most recent
      conversation in `cwd` via `--continue`; because each harness job owns one
      worktree, "the latest session in `cwd`" is unambiguous. The
      `Harness.AgentAdapter.Invocation` `session` field stays an opaque
      pass-through value each adapter interprets as it needs.
    * **Availability probe.** A `version/0` / "is the binary installed" callback
      is anticipated for the capability + availability registry and will be
      added then as an optional callback.
  """

  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.OSProcess
  alias Harness.AgentAdapter.Run

  # The shell and script every agent is spawned through — see spawn_run/5 for
  # why a headless agent CLI cannot be handed a raw OTP-port stdin.
  @sh "/bin/sh"
  @stdin_eof_script ~S(exec "$0" "$@" </dev/null)

  @doc false
  defmacro __using__(_opts \\ []) do
    quote do
      @behaviour Harness.AgentAdapter

      @impl true
      def classify_message(message, run), do: Harness.AgentAdapter.classify_message(message, run)

      @impl true
      def terminate(run), do: Harness.AgentAdapter.terminate(run)

      defoverridable classify_message: 2, terminate: 1
    end
  end

  @typedoc """
  A built headless command: the executable, its argv, and environment pairs.
  The env list carries caller (and adapter) overrides: `{key, value}` sets,
  `{key, false}` unsets an inherited variable.
  """
  @type command ::
          {executable :: String.t(), argv :: [String.t()], env :: [{String.t(), String.t() | false}]}

  @typedoc """
  The result of classifying one process message against a run.

    * `{:output, iodata, run}` — a chunk of the agent's raw output, verbatim.
    * `{:terminated, run, exit_status}` — the agent process closed. `exit_status`
      is advisory only and must never decide run success.
    * `{:error, reason, run}` — an infrastructure failure: the port itself
      failed, or the run could not execute. Distinct from `:terminated` so a
      retry policy can tell a broken run from a finished one.
    * `:ignore` — the message does not belong to this run.
  """
  @type classification ::
          {:output, iodata(), Run.t()}
          | {:terminated, Run.t(), exit_status :: integer() | nil}
          | {:error, reason :: term(), Run.t()}
          | :ignore

  @typedoc "A capability that `supports?/2` can be queried for."
  @type capability :: :session_resume | :streaming_output | {:permission_mode, atom()}

  @doc """
  Declares what the agent's headless mode can do. Static — independent of any
  one run.
  """
  @callback capabilities() :: Capabilities.t()

  @doc """
  Builds the headless command line for invoking the agent.

  Pure — computes the executable, argv, and environment without spawning
  anything. Kept separate from `invoke/2` so it can be unit-tested directly.
  """
  @callback build_command(Invocation.t()) :: {:ok, command()} | {:error, term()}

  @doc """
  Classifies one process message received by the run's driving process.

  This is how raw output is captured — `{:output, iodata, run}` carries the
  agent's bytes untouched — and how termination is detected, from the port
  closing rather than the exit code.
  """
  @callback classify_message(message :: term(), Run.t()) :: classification()

  @doc """
  Kills an in-flight run: terminates the agent's OS process and releases its
  port. Must be idempotent — safe to call on a run that has already ended.
  """
  @callback terminate(Run.t()) :: :ok

  # Default implementations for the two universal callbacks. Adapters `use
  # Harness.AgentAdapter` inherit these via the forwarding def + defoverridable;
  # they only implement capabilities/0 and build_command/1 unless they need custom
  # classification or termination logic.
  @doc "Default implementation (port data → raw output, exit_status → terminated)."
  @spec classify_message(term(), Run.t()) :: classification()
  def classify_message({port, {:data, data}}, %Run{port: port} = run), do: {:output, data, run}
  def classify_message({port, {:exit_status, status}}, %Run{port: port} = run), do: {:terminated, run, status}
  def classify_message(_message, _run), do: :ignore

  @doc "Default implementation: delegates to `OSProcess.kill/1` (idempotent)."
  @spec terminate(Run.t()) :: :ok
  def terminate(%Run{} = run), do: OSProcess.kill(run)

  @doc """
  Spawns `adapter` for an invocation and returns a run handle.

  Builds the command with the adapter's `c:build_command/1`, spawns it over a
  port, and returns a populated `Harness.AgentAdapter.Run`. Must be called from
  the process that will drive the run: the spawned port is connected to the
  caller, so every later port message is delivered there.
  """
  @spec invoke(module(), Invocation.t()) :: {:ok, Run.t()} | {:error, term()}
  def invoke(adapter, %Invocation{} = invocation) do
    case adapter.build_command(invocation) do
      {:ok, {executable, argv, env}} -> spawn_run(adapter, invocation, executable, argv, env)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Returns whether `adapter` supports `capability`, reading the adapter's
  `c:capabilities/0` declaration.
  """
  @spec supports?(module(), capability()) :: boolean()
  def supports?(adapter, capability), do: capability_supported?(adapter.capabilities(), capability)

  @doc """
  Returns `["--model", model]` when `model` is a binary, `[]` otherwise.

  Shared argv helper for any adapter whose headless CLI accepts `--model`.
  """
  @spec model_args(String.t() | nil) :: [String.t()]
  def model_args(nil), do: []
  def model_args(model) when is_binary(model), do: ["--model", model]

  # Spawns the agent over an OTP port and returns its run handle.
  #
  # The agent is not spawned directly. It goes through
  # `/bin/sh -c 'exec "$0" "$@" </dev/null' <agent> <argv…>`. An OTP port leaves
  # the spawned process's stdin an open, empty pipe, and a headless agent CLI
  # that peeks stdin — to support `cat prompt.txt | agent -p` — stalls on input
  # that never arrives (`claude` prints "no stdin data received in 3s" and then
  # bails without doing the task). Redirecting the exec'd process's stdin from
  # `/dev/null` hands it an immediate EOF, so it proceeds at once.
  #
  # `exec` replaces the shell in place — the port's OS pid is the agent itself,
  # never a surviving `sh` parent, so `os_pid` and `terminate/1` still reach it.
  # The real executable and argv ride as positional parameters (`$0`, `$@`), so
  # no argument is ever exposed to shell word-splitting, globbing, or expansion —
  # the agent prompt can carry any bytes. `System.find_executable/1` still runs
  # first: it keeps the clean `{:error, {:executable_not_found, _}}` signal and
  # resolves the absolute path `exec` runs regardless of the shell's own PATH.
  #
  # `:stderr_to_stdout` folds the agent's stderr into the captured stream —
  # diagnostics, auth errors, and partial-failure context all reach the consumer
  # rather than leaking to the BEAM's own stderr. Raw passthrough means the AI
  # reading the transcript tolerates interleaved stderr; losing it would not.
  @spec spawn_run(module(), Invocation.t(), String.t(), [String.t()], [{String.t(), String.t() | false}]) ::
          {:ok, Run.t()} | {:error, term()}
  defp spawn_run(adapter, invocation, executable, argv, env) do
    case System.find_executable(executable) do
      nil ->
        {:error, {:executable_not_found, executable}}

      path ->
        port =
          Port.open({:spawn_executable, @sh}, [
            :binary,
            :exit_status,
            :hide,
            :stderr_to_stdout,
            {:args, ["-c", @stdin_eof_script, path | argv]},
            {:cd, invocation.cwd},
            {:env, port_env(env)}
          ])

        {:ok,
         %Run{
           ref: make_ref(),
           adapter: adapter,
           port: port,
           os_pid: OSProcess.os_pid(port),
           started_at: System.monotonic_time()
         }}
    end
  end

  @spec port_env([{String.t(), String.t() | false}]) :: [{charlist(), charlist() | false}]
  defp port_env(env) do
    Enum.map(env, fn
      {key, false} -> {String.to_charlist(key), false}
      {key, value} -> {String.to_charlist(key), String.to_charlist(value)}
    end)
  end

  @spec capability_supported?(Capabilities.t(), capability()) :: boolean()
  defp capability_supported?(%Capabilities{session_resume: value}, :session_resume), do: value
  defp capability_supported?(%Capabilities{streaming_output: value}, :streaming_output), do: value

  defp capability_supported?(%Capabilities{permission_modes: modes}, {:permission_mode, mode}), do: mode in modes
end
