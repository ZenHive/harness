defmodule Harness.AgentAdapter.Antigravity do
  @moduledoc """
  The headless adapter for the Antigravity CLI (`agy`) — driven via `agy` over an OTP port.

  Like every adapter it is thin: all the real logic is `build_command/1` assembling
  the headless command line. Raw output is captured and passed through unparsed;
  termination is detected from the port closing, never from the exit code.

  ## Invocation

  Runs `agy -p "<prompt>"` for headless execution.

  ## Working directory / workspace

  **Does not honor the port `cwd`.** `Harness.AgentAdapter.invoke/2` sets the
  port's `:cd` to the run worktree, but `agy` ignores it for workspace
  resolution. The CLI exposes no `--cwd`, `--workspace`, or `--project` flag;
  `--add-dir` is the only directory control and it is *additive* — it widens
  the workspace rather than replacing it.

  `agy` resolves its workspace from git metadata (following a linked worktree's
  `.git` file back to the main checkout's common git dir) or from a configured /
  last-used workspace. During dogfooding it edited the *main checkout* while
  the run worktree stayed clean. Harness therefore declares
  `worktree_isolation: false` and rejects Antigravity dispatch before spawn.

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

  @doc false
  @spec worktree_isolation_limitation() :: String.t()
  def worktree_isolation_limitation do
    "agy ignores the port cwd and resolves workspace via git-common-dir to the main checkout; " <>
      "harness cannot headlessly constrain it to a run worktree"
  end

  @doc """
  Declares Antigravity's capabilities: session resume and streaming output,
  with `:autonomous` the only permission mode. Worktree isolation is unsupported.
  """
  @impl AgentAdapter
  @spec capabilities() :: Capabilities.t()
  def capabilities do
    %Capabilities{
      session_resume: true,
      permission_modes: [:autonomous],
      streaming_output: true,
      worktree_isolation: false
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
      argv = ["-p", AgentAdapter.task_prompt(invocation), permission] ++ resume
      env = Map.to_list(invocation.env)
      {:ok, {"agy", argv, env}}
    end
  end

  @spec validate_model(String.t() | nil) :: :ok | {:error, {:unsupported_model, String.t()}}
  defp validate_model(nil), do: :ok
  defp validate_model(model), do: {:error, {:unsupported_model, model}}
end
