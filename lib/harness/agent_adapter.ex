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

  An adapter declares `@behaviour Harness.AgentAdapter` and implements four
  callbacks — `c:capabilities/0`, `c:build_command/1`, `c:classify_message/2`,
  `c:terminate/1`:

      defmodule MyAgent.Adapter do
        @behaviour Harness.AgentAdapter
        alias Harness.AgentAdapter.Capabilities

        @impl true
        def capabilities, do: %Capabilities{session_resume: true}

        @impl true
        def build_command(invocation),
          do: {:ok, {"my-agent", ["-p", invocation.prompt], []}}

        @impl true
        def classify_message({port, {:data, data}}, %{port: port} = run),
          do: {:output, data, run}

        def classify_message({port, {:exit_status, status}}, %{port: port} = run),
          do: {:terminated, run, status}

        def classify_message(_other, _run), do: :ignore

        @impl true
        def terminate(_run), do: :ok
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

  ## Deliberate deferrals

    * **Session-token extraction.** `Harness.AgentAdapter.Invocation` carries
      `session` as an opaque pass-through token. Whether resume needs a
      dedicated token-extraction callback — versus resuming the latest session
      in `cwd`, which needs none — is resolved when the first concrete adapter
      (the Claude Code adapter) lands.
    * **Availability probe.** A `version/0` / "is the binary installed" callback
      is anticipated for the capability + availability registry and will be
      added then as an optional callback.
  """

  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Run

  @typedoc """
  A built headless command: the executable, its argv, and environment pairs.
  """
  @type command ::
          {executable :: String.t(), argv :: [String.t()], env :: [{String.t(), String.t()}]}

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

  @spec spawn_run(module(), Invocation.t(), String.t(), [String.t()], [{String.t(), String.t()}]) ::
          {:ok, Run.t()} | {:error, term()}
  defp spawn_run(adapter, invocation, executable, argv, env) do
    case System.find_executable(executable) do
      nil ->
        {:error, {:executable_not_found, executable}}

      path ->
        port =
          Port.open({:spawn_executable, path}, [
            :binary,
            :exit_status,
            :hide,
            {:args, argv},
            {:cd, invocation.cwd},
            {:env, port_env(env)}
          ])

        {:ok,
         %Run{
           ref: make_ref(),
           adapter: adapter,
           port: port,
           os_pid: port_os_pid(port),
           started_at: System.monotonic_time()
         }}
    end
  end

  @spec port_env([{String.t(), String.t()}]) :: [{charlist(), charlist()}]
  defp port_env(env) do
    Enum.map(env, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end

  @spec port_os_pid(port()) :: non_neg_integer() | nil
  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      nil -> nil
    end
  end

  @spec capability_supported?(Capabilities.t(), capability()) :: boolean()
  defp capability_supported?(%Capabilities{session_resume: value}, :session_resume), do: value
  defp capability_supported?(%Capabilities{streaming_output: value}, :streaming_output), do: value

  defp capability_supported?(%Capabilities{permission_modes: modes}, {:permission_mode, mode}), do: mode in modes
end
