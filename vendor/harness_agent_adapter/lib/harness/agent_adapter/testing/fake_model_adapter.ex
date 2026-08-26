defmodule Harness.AgentAdapter.Testing.FakeModelAdapter do
  @moduledoc """
  Model-CAPABLE twin of `Harness.AgentAdapter.Testing.FakeAdapter`, for
  model-threading fixtures.

  `FakeAdapter` declares `model_families: []` — honestly model-INCAPABLE, since
  it spawns shell builtins and ignores `Harness.AgentAdapter.Invocation.model`
  entirely. That keeps a caller's model-required guard from rejecting the
  nil-model lifecycle and reviewer fixtures.

  Model-threading tests need the opposite: a non-nil pin that survives the
  guard, so it can be observed arriving at the spawned process through the same
  `:capture_model` / `{:review_capture_model, _}` command branches. This twin
  declares `model_families: :any` for that, and delegates `build_command/1` to
  `FakeAdapter` so both fixtures share one command table.
  """

  use Harness.AgentAdapter

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Testing.FakeAdapter

  @doc """
  Declares `model_families: :any`, so a pinned model is accepted rather than
  rejected by a model-capability guard.
  """
  @impl AgentAdapter
  @spec capabilities() :: Capabilities.t()
  def capabilities do
    %Capabilities{session_resume: true, permission_modes: [:autonomous, :plan], model_families: :any}
  end

  @doc """
  No rule injection — the fixture spawns shell builtins that read no rules.
  """
  @impl AgentAdapter
  @spec rule_channel() :: AgentAdapter.rule_channel()
  def rule_channel, do: :none

  @doc """
  Delegates to `Harness.AgentAdapter.Testing.FakeAdapter.build_command/1`, so
  both fixtures resolve the same command branches.
  """
  @impl AgentAdapter
  @spec build_command(Invocation.t()) :: {:ok, AgentAdapter.command()} | {:error, term()}
  defdelegate build_command(invocation), to: FakeAdapter
end
