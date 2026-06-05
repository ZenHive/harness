defmodule Harness.AgentAdapter.Antigravity do
  @moduledoc """
  The headless adapter for the Antigravity CLI (`agy`) — driven via `agy` over an OTP port.

  Like every adapter it is thin: all the real logic is `build_command/1` assembling
  the headless command line. Raw output is captured and passed through unparsed;
  termination is detected from the port closing, never from the exit code.

  ## Invocation

  Runs `agy -p "<prompt>"` for headless execution.

  ## Working directory / workspace

  `agy` does **not** honor the port `:cd` alone for file writes (Task 32, Task
  198): it resolves workspace via git metadata and can edit the main checkout
  while the run worktree stays clean. Isolation is pinned on two channels, like
  Codex's `--cd` fix (Task 41): the port `:cd` **and** `--add-dir <worktree>`
  in `build_command/1`. `--add-dir` is the load-bearing flag — `agy` exposes no
  `--cwd` / `--workspace` replacement, only this repeatable workspace add.

  ## Permission mode

  `Harness.AgentAdapter.Invocation`'s `permission_mode` maps to Antigravity's
  `--dangerously-skip-permissions` flag to bypass permissions during autonomous execution.
  Only `:autonomous` permission mode is supported.

  ## Session resume

  Resuming uses `--continue` for session resumption. The `Invocation` `session`
  field therefore carries the `:resume` sentinel, not a literal token; any other
  non-`nil` value is an error.

  ## Model Override

  The `agy` CLI does not expose a `--model` flag at the command line level. If a model
  is specified in the invocation, the adapter will return `{:error, {:unsupported_model, model}}`.
  """

  use Harness.AgentAdapter

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation

  @permission_modes %{autonomous: "--dangerously-skip-permissions"}

  @doc """
  Declares Antigravity's capabilities: session resume and streaming output,
  with `:autonomous` the only permission mode.
  """
  @impl AgentAdapter
  @spec capabilities() :: Capabilities.t()
  def capabilities do
    # Intentionally no `auth_env_scrub`: official Antigravity CLI auth docs
    # describe secure-keyring, browser, and SSH OAuth flows with no API-key env
    # var; local `agy` help/strings do not verify `GEMINI_API_KEY` or
    # `GOOGLE_API_KEY` as CLI auth overrides.
    # Source: https://antigravity.google/docs/cli-install
    %Capabilities{
      session_resume: true,
      permission_modes: [:autonomous],
      streaming_output: true,
      worktree_isolation: true
    }
  end

  @impl AgentAdapter
  @spec rule_channel() :: AgentAdapter.rule_channel()
  def rule_channel, do: :prompt_preamble

  @doc """
  Builds the `agy` headless command line for `invocation`.

  Returns `{:error, {:unsupported_model, model}}` if a model is specified,
  `{:error, {:unsupported_permission_mode, mode}}` for a permission mode outside `capabilities/0`,
  and `{:error, {:unsupported_session_token, value}}` when `session` is neither `nil` nor `:resume`.
  """
  @impl AgentAdapter
  @spec build_command(Invocation.t()) :: {:ok, AgentAdapter.command()} | {:error, term()}
  def build_command(%Invocation{} = invocation) do
    with {:ok, invocation} <- AgentAdapter.attach_rules(__MODULE__, invocation),
         :ok <- validate_model(invocation.model),
         {:ok, permission} <- AgentAdapter.permission_flag(@permission_modes, invocation.permission_mode),
         {:ok, resume} <- AgentAdapter.resume_args(invocation.session) do
      argv =
        ["--add-dir", invocation.cwd, permission] ++
          resume ++
          ["-p", AgentAdapter.task_prompt(invocation)]

      env = Map.to_list(invocation.env)
      {:ok, {"agy", argv, env}}
    end
  end

  @spec validate_model(String.t() | nil) :: :ok | {:error, {:unsupported_model, String.t()}}
  defp validate_model(nil), do: :ok
  defp validate_model(model), do: {:error, {:unsupported_model, model}}
end
