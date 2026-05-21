defmodule Harness.AgentAdapter.Cursor do
  @moduledoc """
  The headless adapter for Cursor — driven via `cursor-agent -p` over an OTP port.

  The third concrete `Harness.AgentAdapter`, after Claude Code and the
  process-spawning fake. Like every adapter it is thin: all the real logic is
  `build_command/1` assembling the headless command line. Raw output is captured
  and passed through unparsed; termination is detected from the port closing,
  never from the exit code. `classify_message/2` and `terminate/1` are the
  agent-agnostic shapes the behaviour proved against Claude — Cursor reuses them
  unchanged, which is the conformance suite's point.

  ## Invocation

  Runs `cursor-agent -p` (print / non-interactive mode) with `--output-format
  stream-json` so the full agent transcript streams out as raw NDJSON, captured
  verbatim. The working directory is wired by `Harness.AgentAdapter.invoke/2`
  (the port's `:cd`), not here — `cursor-agent` defaults its workspace to `cwd`.

  ## Permission mode

  `Harness.AgentAdapter.Invocation`'s `permission_mode` selects Cursor's
  autonomy flags. `:autonomous` — harness's unattended baseline — maps to
  `--force --trust`: harness runs in a throwaway worktree with no human to
  answer prompts, so the agent must run commands without asking (`--force`) and
  trust the never-before-seen worktree without prompting (`--trust`, which Cursor
  documents as headless-mode-only and exactly the fresh-untrusted-directory
  case). An unrecognized mode is a `build_command/1` error rather than a silent
  fallback.

  ## Session resume

  Resuming uses `--continue`, which Cursor documents as shorthand for
  `--resume=-1` — it reloads the most recent session. That is exact here because
  every harness job owns one worktree invoked as Cursor's workspace, so "the
  most recent session" is unambiguous. Harness cannot obtain a Cursor chat id
  without parsing agent output — which the raw-passthrough design forbids — so
  `--continue` is the only viable resume channel. The `Invocation` `session`
  field therefore carries the `:resume` sentinel, not a literal chat id; any
  other non-`nil` value is an error.
  """

  @behaviour Harness.AgentAdapter

  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.OSProcess
  alias Harness.AgentAdapter.Run

  # Harness permission-mode vocabulary -> the cursor-agent autonomy flags it
  # selects. :autonomous needs both --force (run commands without approval) and
  # --trust (skip the workspace-trust prompt on a fresh worktree).
  @permission_modes %{autonomous: ["--force", "--trust"]}

  @doc """
  Declares Cursor's headless capabilities: session resume and streaming output,
  with `:autonomous` the only permission mode.
  """
  @impl Harness.AgentAdapter
  @spec capabilities() :: Capabilities.t()
  def capabilities, do: %Capabilities{session_resume: true}

  @doc """
  Builds the `cursor-agent -p` headless command line for `invocation`.

  Returns `{:error, {:unsupported_permission_mode, mode}}` for a permission mode
  outside `capabilities/0`, and `{:error, {:unsupported_session_token, value}}`
  when `session` is neither `nil` nor `:resume` (see the module doc — Cursor
  resumes the most recent session, not a chat id).
  """
  @impl Harness.AgentAdapter
  @spec build_command(Invocation.t()) :: {:ok, Harness.AgentAdapter.command()} | {:error, term()}
  def build_command(%Invocation{} = invocation) do
    with {:ok, permission} <- permission_flags(invocation.permission_mode),
         {:ok, resume} <- resume_args(invocation.session) do
      argv =
        ["-p", "--output-format", "stream-json"] ++
          permission ++
          model_args(invocation.model) ++
          resume ++
          [invocation.prompt]

      {:ok, {"cursor-agent", argv, []}}
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

  @spec permission_flags(atom()) ::
          {:ok, [String.t()]} | {:error, {:unsupported_permission_mode, atom()}}
  defp permission_flags(mode) do
    case Map.fetch(@permission_modes, mode) do
      {:ok, flags} -> {:ok, flags}
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
