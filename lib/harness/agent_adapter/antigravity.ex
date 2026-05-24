defmodule Harness.AgentAdapter.Antigravity do
  @moduledoc """
  The headless adapter for the Antigravity CLI (`agy`) — driven via `agy` over an OTP port.

  Like every adapter it is thin: all the real logic is `build_command/1` assembling
  the headless command line. Raw output is captured and passed through unparsed;
  termination is detected from the port closing, never from the exit code.

  ## Invocation

  Runs `agy -p "<prompt>"` for headless execution. The working directory is wired
  by `Harness.AgentAdapter.invoke/2` (the port's `:cd`), not here.

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

  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.RulesInjection

  @permission_modes %{autonomous: "--dangerously-skip-permissions"}

  @doc """
  Declares Antigravity's capabilities: session resume and streaming output,
  with `:autonomous` the only permission mode.
  """
  @impl Harness.AgentAdapter
  @spec capabilities() :: Capabilities.t()
  def capabilities do
    %Capabilities{
      session_resume: true,
      permission_modes: [:autonomous],
      streaming_output: true
    }
  end

  @doc """
  Builds the `agy` headless command line for `invocation`.

  Returns `{:error, {:unsupported_model, model}}` if a model is specified,
  `{:error, {:unsupported_permission_mode, mode}}` for a permission mode outside `capabilities/0`,
  and `{:error, {:unsupported_session_token, value}}` when `session` is neither `nil` nor `:resume`.
  """
  @impl Harness.AgentAdapter
  @spec build_command(Invocation.t()) :: {:ok, Harness.AgentAdapter.command()} | {:error, term()}
  def build_command(%Invocation{} = invocation) do
    with :ok <- validate_model(invocation.model),
         {:ok, permission} <- permission_flag(invocation.permission_mode),
         {:ok, resume} <- resume_args(invocation.session) do
      argv = ["-p", RulesInjection.prepend_prompt(invocation.prompt), permission] ++ resume
      env = Map.to_list(invocation.env)
      {:ok, {"agy", argv, env}}
    end
  end

  @spec validate_model(String.t() | nil) :: :ok | {:error, {:unsupported_model, String.t()}}
  defp validate_model(nil), do: :ok
  defp validate_model(model), do: {:error, {:unsupported_model, model}}

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
