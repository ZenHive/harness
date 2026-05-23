defmodule Harness.AgentAdapter.Claude do
  @moduledoc """
  The headless adapter for Claude Code — driven via `claude -p` over an OTP port.

  The first concrete `Harness.AgentAdapter`. Like every adapter it is thin: all
  the real logic is `build_command/1` assembling the headless command line. Raw
  output is captured and passed through unparsed; termination is detected from
  the port closing, never from the exit code.

  ## Invocation

  Runs `claude -p` with `--output-format stream-json --verbose` so the full
  agent transcript streams out as raw NDJSON, captured verbatim. The working
  directory is wired by `Harness.AgentAdapter.invoke/2` (the port's `:cd`), not
  here.

  ## Permission mode

  `Harness.AgentAdapter.Invocation`'s `permission_mode` maps to Claude's
  `--permission-mode`. `:autonomous` — harness's unattended baseline — maps to
  `bypassPermissions`: harness runs in a throwaway worktree with no human to
  answer prompts, so the agent must edit files and run commands without asking.
  An unrecognized mode is a `build_command/1` error rather than a silent
  fallback.

  ## Session resume

  Resuming uses `--continue`, which reloads the most recent conversation **in
  the working directory**. That is exact here because every harness job owns one
  worktree, so "the most recent conversation in `cwd`" is unambiguous. Harness
  cannot obtain a Claude session id without parsing agent output — which the
  raw-passthrough design forbids — so `--continue` is the only viable resume
  channel. The `Invocation` `session` field therefore carries the `:resume`
  sentinel, not a literal token; any other non-`nil` value is an error.
  """

  @behaviour Harness.AgentAdapter

  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.OSProcess
  alias Harness.AgentAdapter.RulesInjection
  alias Harness.AgentAdapter.Run

  # Harness permission-mode vocabulary -> Claude --permission-mode value.
  @permission_modes %{autonomous: "bypassPermissions"}

  @doc """
  Declares Claude Code's headless capabilities: session resume and streaming
  output, with `:autonomous` the only permission mode.
  """
  @impl Harness.AgentAdapter
  @spec capabilities() :: Capabilities.t()
  def capabilities, do: %Capabilities{session_resume: true}

  @doc """
  Builds the `claude -p` headless command line for `invocation`.

  Returns `{:error, {:unsupported_permission_mode, mode}}` for a permission mode
  outside `capabilities/0`, and `{:error, {:unsupported_session_token, value}}`
  when `session` is neither `nil` nor `:resume` (see the module doc — Claude
  resumes the latest conversation in `cwd`, not a token).
  """
  @impl Harness.AgentAdapter
  @spec build_command(Invocation.t()) :: {:ok, Harness.AgentAdapter.command()} | {:error, term()}
  def build_command(%Invocation{} = invocation) do
    with {:ok, permission} <- permission_flag(invocation.permission_mode),
         {:ok, resume} <- resume_args(invocation.session),
         {:ok, rules} <- RulesInjection.claude_flags(invocation) do
      argv =
        ["-p", "--output-format", "stream-json", "--verbose", "--permission-mode", permission] ++
          rules ++
          model_args(invocation.model) ++
          resume ++
          [invocation.prompt]

      env = Map.to_list(invocation.env)
      {:ok, {"claude", argv, env}}
    end
  end

  @doc """
  Classifies one port message: a data chunk is raw output, an exit status is
  termination, anything else is ignored.
  """
  @impl Harness.AgentAdapter
  @spec classify_message(term(), Run.t()) :: Harness.AgentAdapter.classification()
  def classify_message({port, {:data, data}}, %Run{port: port} = run), do: {:output, data, run}

  def classify_message({port, {:exit_status, status}}, %Run{port: port} = run), do: {:terminated, run, status}

  def classify_message(_message, _run), do: :ignore

  @doc """
  Kills an in-flight run, delegating to the shared `Harness.AgentAdapter.OSProcess.kill/1`.
  """
  @impl Harness.AgentAdapter
  @spec terminate(Run.t()) :: :ok
  def terminate(%Run{} = run), do: OSProcess.kill(run)

  @spec permission_flag(atom()) ::
          {:ok, String.t()} | {:error, {:unsupported_permission_mode, atom()}}
  defp permission_flag(mode) do
    case Map.fetch(@permission_modes, mode) do
      {:ok, flag} -> {:ok, flag}
      :error -> {:error, {:unsupported_permission_mode, mode}}
    end
  end

  @spec resume_args(term()) ::
          {:ok, [String.t()]} | {:error, {:unsupported_session_token, term()}}
  defp resume_args(nil), do: {:ok, []}
  defp resume_args(:resume), do: {:ok, ["--continue"]}
  defp resume_args(other), do: {:error, {:unsupported_session_token, other}}

  @spec model_args(String.t() | nil) :: [String.t()]
  defp model_args(nil), do: []
  defp model_args(model) when is_binary(model), do: ["--model", model]
end
