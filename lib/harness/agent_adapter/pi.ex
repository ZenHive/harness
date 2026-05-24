defmodule Harness.AgentAdapter.Pi do
  @moduledoc """
  The headless adapter for pi.dev — driven via `pi -p --mode json` over an OTP port.

  Like every `Harness.AgentAdapter` it is thin: all the real logic is
  `build_command/1` assembling the headless command line. Raw output is
  captured and passed through unparsed; termination is detected from the port
  closing, never from the exit code.

  ## Invocation

  Runs `pi -p --mode json <prompt>`: `-p` / `--print` is pi's headless
  print-and-exit mode, `--mode json` switches the output to a one-event-per-line
  JSON event stream, captured verbatim. The working directory is wired by
  `Harness.AgentAdapter.invoke/2` (the port's `:cd`), not here.

  ## Permission mode

  pi.dev has no built-in permission-bypass flag — its design exposes the
  built-in tools by default and leaves "permission gates" to extensions, so the
  unattended baseline is the *default* binary behaviour and nothing extra is
  added to argv. `:autonomous` is the only mode accepted; any other value is a
  `build_command/1` error rather than a silent fallback.

  ## Rules injection

  pi auto-discovers `AGENTS.md` from cwd (walking up parent directories and
  reading `~/.pi/agent/AGENTS.md` for global preferences), the same mechanism
  Codex uses. `rule_channel/0` therefore returns `:codex_ephemeral_file`: the
  canonical harness rule set is written into the run worktree by
  `Harness.AgentAdapter.attach_rules/2` and cleaned up by
  `Harness.AgentRules.cleanup_injected_rules/1` before delivery.

  ## Session resume

  Resuming uses `--continue`, pi's flag for "reload the most recent session".
  That is exact here because every harness job owns one worktree, so "the most
  recent session in `cwd`" is unambiguous — the same reasoning as the Claude
  adapter's `--continue`. Harness cannot obtain a pi session id without parsing
  agent output — which the raw-passthrough design forbids — so `--continue` is
  the only viable resume channel. The `Invocation` `session` field therefore
  carries the `:resume` sentinel, not a literal token; any other non-`nil`
  value is an error.

  ## Pi-specific extras

  pi.dev's headless-only knobs (`--provider`, `--thinking`, `--tools`,
  `--no-builtin-tools`, `--skill`, `--extension`, `--no-context-files`,
  `--fork`, `--no-session`) are deliberately absent from `build_command/1`.
  They are not part of the core `Harness.AgentAdapter` behaviour; they belong
  to the capability + availability registry (Task 16), which surfaces
  per-agent extras without widening the four-callback contract.
  """

  use Harness.AgentAdapter

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation

  # pi.dev exposes no permission-bypass flag — `:autonomous` is the default
  # behaviour of the binary, so the mode is accepted without adding anything
  # to argv. An undeclared mode is a build_command/1 error.
  @permission_modes [:autonomous]

  @doc """
  Declares pi.dev's headless capabilities: session resume and streaming output,
  with `:autonomous` the only permission mode.
  """
  @impl AgentAdapter
  @spec capabilities() :: Capabilities.t()
  def capabilities, do: %Capabilities{session_resume: true}

  @impl AgentAdapter
  @spec rule_channel() :: AgentAdapter.rule_channel()
  def rule_channel, do: :codex_ephemeral_file

  @doc """
  Builds the `pi -p --mode json` headless command line for `invocation`.

  Returns `{:error, {:unsupported_permission_mode, mode}}` for a permission mode
  outside `capabilities/0`, and `{:error, {:unsupported_session_token, value}}`
  when `session` is neither `nil` nor `:resume` (see the module doc — pi
  resumes the latest session via `--continue`, not a token).
  """
  @impl AgentAdapter
  @spec build_command(Invocation.t()) :: {:ok, AgentAdapter.command()} | {:error, term()}
  def build_command(%Invocation{} = invocation) do
    with {:ok, invocation} <- AgentAdapter.attach_rules(__MODULE__, invocation),
         :ok <- check_permission_mode(invocation.permission_mode),
         {:ok, resume} <- resume_args(invocation.session) do
      argv =
        ["-p", "--mode", "json"] ++
          AgentAdapter.model_args(invocation.model) ++
          resume ++
          [AgentAdapter.task_prompt(invocation)]

      env = Map.to_list(invocation.env)
      {:ok, {"pi", argv, env}}
    end
  end

  @spec check_permission_mode(atom()) ::
          :ok | {:error, {:unsupported_permission_mode, atom()}}
  defp check_permission_mode(mode) when mode in @permission_modes, do: :ok
  defp check_permission_mode(mode), do: {:error, {:unsupported_permission_mode, mode}}

  @spec resume_args(term()) ::
          {:ok, [String.t()]} | {:error, {:unsupported_session_token, term()}}
  defp resume_args(nil), do: {:ok, []}
  defp resume_args(:resume), do: {:ok, ["--continue"]}
  defp resume_args(other), do: {:error, {:unsupported_session_token, other}}
end
