defmodule Harness.AgentAdapter.Cursor do
  @moduledoc """
  The headless adapter for Cursor — driven via `cursor-agent -p` over an OTP port.

  The third concrete `Harness.AgentAdapter`, after Claude Code and the
  process-spawning fake. Like every adapter it is thin: all the real logic is
  `build_command/1` assembling the headless command line. Raw output is captured
  and passed through unparsed; termination is detected from the port closing,
  never from the exit code.

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

  use Harness.AgentAdapter

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation

  # Harness permission-mode vocabulary -> the cursor-agent autonomy flags it
  # selects. :autonomous needs both --force (run commands without approval) and
  # --trust (skip the workspace-trust prompt on a fresh worktree).
  @permission_modes %{autonomous: ["--force", "--trust"]}

  @doc """
  Declares Cursor's headless capabilities: session resume and streaming output,
  with `:autonomous` the only permission mode.
  """
  @impl AgentAdapter
  @spec capabilities() :: Capabilities.t()
  # Source: Cursor CLI auth docs and `cursor-agent --help` declare two auth
  # methods: browser login and API-key auth via `CURSOR_API_KEY` / `--api-key`.
  # https://docs.cursor.com/en/cli/reference/authentication
  def capabilities, do: %Capabilities{session_resume: true, auth_env_scrub: ["CURSOR_API_KEY"]}

  @impl AgentAdapter
  @spec rule_channel() :: AgentAdapter.rule_channel()
  def rule_channel, do: :cursor_ephemeral_file

  @doc """
  Builds the `cursor-agent -p` headless command line for `invocation`.

  Returns `{:error, {:unsupported_permission_mode, mode}}` for a permission mode
  outside `capabilities/0`, and `{:error, {:unsupported_session_token, value}}`
  when `session` is neither `nil` nor `:resume` (see the module doc — Cursor
  resumes the most recent session, not a chat id).
  """
  @impl AgentAdapter
  @spec build_command(Invocation.t()) :: {:ok, AgentAdapter.command()} | {:error, term()}
  def build_command(%Invocation{} = invocation) do
    with {:ok, invocation} <- AgentAdapter.attach_rules(__MODULE__, invocation),
         {:ok, permission} <- AgentAdapter.permission_flag(@permission_modes, invocation.permission_mode),
         {:ok, resume} <- AgentAdapter.resume_args(invocation.session) do
      argv =
        ["-p", "--output-format", "stream-json"] ++
          permission ++
          AgentAdapter.model_args(invocation.model) ++
          resume ++
          [AgentAdapter.task_prompt(invocation)]

      env = Map.to_list(invocation.env)
      {:ok, {"cursor-agent", argv, env}}
    end
  end
end
