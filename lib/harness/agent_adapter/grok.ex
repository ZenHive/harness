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

  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.RulesInjection

  # Harness permission-mode vocabulary -> Grok --permission-mode value.
  @permission_modes %{autonomous: "bypassPermissions"}

  @doc """
  Declares Grok's headless capabilities: session resume and streaming output,
  with `:autonomous` the only permission mode.
  """
  @impl Harness.AgentAdapter
  @spec capabilities() :: Capabilities.t()
  def capabilities, do: %Capabilities{session_resume: true}

  @doc """
  Builds the `grok -p` headless command line for `invocation`.

  Returns `{:error, {:unsupported_permission_mode, mode}}` for a permission mode
  outside `capabilities/0`, and `{:error, {:unsupported_session_token, value}}`
  when `session` is neither `nil` nor `:resume` (see the module doc — Grok
  resumes the latest session in `cwd`, not a token).
  """
  @impl Harness.AgentAdapter
  @spec build_command(Invocation.t()) :: {:ok, Harness.AgentAdapter.command()} | {:error, term()}
  def build_command(%Invocation{} = invocation) do
    with {:ok, permission} <- permission_flag(invocation.permission_mode),
         {:ok, resume} <- resume_args(invocation.session) do
      argv =
        ["--output-format", "streaming-json", "--permission-mode", permission] ++
          Harness.AgentAdapter.model_args(invocation.model) ++
          resume ++
          ["-p", RulesInjection.prepend_prompt(invocation.prompt)]

      env = Map.to_list(invocation.env)
      {:ok, {"grok", argv, env}}
    end
  end

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
end
