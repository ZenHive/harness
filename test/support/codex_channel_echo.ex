defmodule Harness.AgentDriverTest.CodexChannelEcho do
  @moduledoc false

  use Harness.AgentAdapter

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation

  @impl AgentAdapter
  @spec capabilities() :: Capabilities.t()
  def capabilities do
    %Capabilities{session_resume: false, permission_modes: [:autonomous], model_families: []}
  end

  @impl AgentAdapter
  @spec rule_channel() :: AgentAdapter.rule_channel()
  def rule_channel, do: :codex_ephemeral_file

  @impl AgentAdapter
  @spec build_command(Invocation.t()) :: {:ok, AgentAdapter.command()} | {:error, term()}
  def build_command(%Invocation{} = invocation) do
    with {:ok, invocation} <- AgentAdapter.attach_rules(__MODULE__, invocation) do
      {:ok, {"/bin/echo", [AgentAdapter.task_prompt(invocation)], []}}
    end
  end
end
