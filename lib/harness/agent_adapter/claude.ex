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

  use Harness.AgentAdapter

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation

  # Harness permission-mode vocabulary -> Claude --permission-mode value.
  @permission_modes %{autonomous: "bypassPermissions"}

  @doc """
  Declares Claude Code's headless capabilities: session resume and streaming
  output, with `:autonomous` the only permission mode.
  """
  @impl AgentAdapter
  @spec capabilities() :: Capabilities.t()
  def capabilities, do: %Capabilities{session_resume: true}

  @impl AgentAdapter
  @spec rule_channel() :: AgentAdapter.rule_channel()
  def rule_channel, do: :system_prompt_file

  @doc """
  Builds the `claude -p` headless command line for `invocation`.

  Returns `{:error, {:unsupported_permission_mode, mode}}` for a permission mode
  outside `capabilities/0`, and `{:error, {:unsupported_session_token, value}}`
  when `session` is neither `nil` nor `:resume` (see the module doc — Claude
  resumes the latest conversation in `cwd`, not a token).
  """
  @impl AgentAdapter
  @spec build_command(Invocation.t()) :: {:ok, AgentAdapter.command()} | {:error, term()}
  def build_command(%Invocation{} = invocation) do
    with {:ok, invocation} <- AgentAdapter.attach_rules(__MODULE__, invocation),
         {:ok, permission} <- AgentAdapter.permission_flag(@permission_modes, invocation.permission_mode),
         {:ok, resume} <- AgentAdapter.resume_args(invocation.session),
         %Invocation{rules: %{argv_flags: rules}} <- invocation do
      argv =
        ["-p", "--output-format", "stream-json", "--verbose", "--permission-mode", permission] ++
          rules ++
          AgentAdapter.model_args(invocation.model) ++
          resume ++
          [AgentAdapter.task_prompt(invocation)]

      env = Map.to_list(invocation.env)
      {:ok, {"claude", argv, env}}
    end
  end
end
