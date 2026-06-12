defmodule Harness.AgentAdapter.Grok do
  @moduledoc """
  The headless adapter for Grok Build — driven via `grok -p` over an OTP port.

  Like every `Harness.AgentAdapter` it is thin: all the real logic is
  `build_command/1` assembling the headless command line. Raw output is captured
  and passed through unparsed; termination is detected from the port closing,
  never from the exit code.

  ## Invocation

  Runs `grok -p <prompt>` — `-p`/`--single` is Grok's single-turn headless flag,
  which takes the prompt as its value and exits when the response is done. Paired
  with `--output-format streaming-json` so the full agent transcript streams out
  as raw NDJSON events, captured verbatim.

  ## Permission mode

  `Harness.AgentAdapter.Invocation`'s `permission_mode` maps to Grok's
  `--permission-mode`. `:autonomous` — harness's unattended baseline — maps to
  `bypassPermissions`: harness runs in a throwaway worktree with no human to
  answer prompts, so the agent must edit files and run commands without asking.
  An unrecognized mode is a `build_command/1` error rather than a silent
  fallback.

  ## Working directory

  Wired by `Harness.AgentAdapter.invoke/2` (the port's `:cd`), not here — Grok
  inherits its working directory from the spawned process's cwd. Grok's own
  `--cwd` flag is therefore redundant, and `--worktree` is deliberately *not*
  passed: harness already owns the isolated git worktree the agent runs in.

  ## Session resume

  Resuming uses `--continue`, which reloads the most recent session **for the
  working directory**. That is exact here because every harness job owns one
  worktree, so "the most recent session in `cwd`" is unambiguous. Grok also
  accepts `--resume <session-id>`, but harness cannot obtain a session id
  without parsing agent output — which the raw-passthrough design forbids — so
  `--continue` is the only viable resume channel. The `Invocation` `session`
  field therefore carries the `:resume` sentinel, not a literal token; any other
  non-`nil` value is an error.

  ## Grok-specific extras

  Grok's headless-only knobs — `--best-of-n`, `--check`, the `--worktree`
  flag — are deliberately absent from `build_command/1`. They are not part of
  the core `Harness.AgentAdapter` behaviour; they belong to the capability +
  availability registry (Task 16), which surfaces per-agent extras without
  widening the four-callback contract.
  """

  use Harness.AgentAdapter

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation

  # Harness permission-mode vocabulary -> Grok --permission-mode value.
  @permission_modes %{autonomous: "bypassPermissions"}

  @doc """
  Declares Grok's headless capabilities: session resume and streaming output,
  with `:autonomous` the only permission mode.
  """
  @impl AgentAdapter
  @spec capabilities() :: Capabilities.t()
  # Source: xAI Grok Build docs state `XAI_API_KEY` enables API-key auth in
  # non-browser environments; local `grok 0.2.22` bundled docs/source strings
  # say "`XAI_API_KEY` -- highest priority" and "API key takes precedence over
  # browser credentials." `GROK_CODE_XAI_API_KEY` appears only as a custom-model
  # endpoint fallback, not as the CLI login override.
  # https://docs.x.ai/build/overview
  def capabilities do
    %Capabilities{
      session_resume: true,
      auth_env_scrub: ["XAI_API_KEY"],
      model_families: [:xai]
    }
  end

  @impl AgentAdapter
  @spec rule_channel() :: AgentAdapter.rule_channel()
  def rule_channel, do: :prompt_preamble

  @doc """
  Builds the `grok -p` headless command line for `invocation`.

  Returns `{:error, {:unsupported_permission_mode, mode}}` for a permission mode
  outside `capabilities/0`, and `{:error, {:unsupported_session_token, value}}`
  when `session` is neither `nil` nor `:resume` (see the module doc — Grok
  resumes the latest session in `cwd`, not a token).
  """
  @impl AgentAdapter
  @spec build_command(Invocation.t()) :: {:ok, AgentAdapter.command()} | {:error, term()}
  def build_command(%Invocation{} = invocation) do
    with {:ok, invocation} <- AgentAdapter.attach_rules(__MODULE__, invocation),
         {:ok, permission} <- AgentAdapter.permission_flag(@permission_modes, invocation.permission_mode),
         {:ok, resume} <- AgentAdapter.resume_args(invocation.session) do
      argv =
        ["--output-format", "streaming-json", "--permission-mode", permission] ++
          AgentAdapter.model_args(invocation.model) ++
          resume ++
          ["-p", AgentAdapter.task_prompt(invocation)]

      env = Map.to_list(invocation.env)
      {:ok, {"grok", argv, env}}
    end
  end
end
