defmodule Harness.ResultStore.Schema.RunRecord do
  @moduledoc """
  Ecto schema for the run_records table (Task 137).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:run_id, :string, autogenerate: false}
  schema "run_records" do
    field :batch_id, :string
    field :task_id, :string
    field :project_name, :string
    field :agent, :string
    field :model, :string
    field :adapter, :string
    field :state, :string
    field :verdict, :string
    field :agent_outcome_kind, :string
    field :duration_ms, :integer
    field :repair_attempts, :integer
    field :first_attempt_failed_check_count, :integer
    field :agent_diff_size, :integer
    field :agent_exit_status, :integer

    field :reason, :map
    field :token_usage, :map
    field :composed_inputs, :map
    field :failure_cause, :map
    field :check_output, :map
    field :domains, :map

    field :agent_output, :binary

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = struct, attrs) when is_map(attrs) do
    cast(struct, attrs, [
      :run_id,
      :batch_id,
      :task_id,
      :project_name,
      :agent,
      :model,
      :adapter,
      :state,
      :verdict,
      :agent_outcome_kind,
      :duration_ms,
      :repair_attempts,
      :first_attempt_failed_check_count,
      :agent_diff_size,
      :agent_exit_status,
      :reason,
      :token_usage,
      :composed_inputs,
      :failure_cause,
      :check_output,
      :domains,
      :agent_output
    ])
  end

  @type t :: %__MODULE__{}
end
