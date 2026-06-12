defmodule Harness.FakeModelAdapter do
  @moduledoc false

  # Model-CAPABLE twin of `Harness.FakeAdapter` for the model-THREADING
  # fixtures. FakeAdapter declares `model_families: []` (it ignores the model
  # and spawns shell builtins), so the model-required guard correctly forbids a
  # nil model on it only when capable — i.e. never. The threading tests, though,
  # pass a real pinned model through the same `:capture_model` /
  # `{:review_capture_model, _}` command branches to prove it reaches
  # `Invocation.model`. This twin declares `model_families: :any` so a non-nil
  # pin is accepted, and delegates every other callback to FakeAdapter.

  use Harness.AgentAdapter

  alias Harness.AgentAdapter.Capabilities

  @impl Harness.AgentAdapter
  def capabilities do
    %Capabilities{session_resume: true, permission_modes: [:autonomous, :plan], model_families: :any}
  end

  @impl Harness.AgentAdapter
  def rule_channel, do: :none

  @impl Harness.AgentAdapter
  defdelegate build_command(invocation), to: Harness.FakeAdapter
end
