defmodule Harness.ResultStore.Schema.RunRecord do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:run_id, :string, autogenerate: false}
  schema "run_records" do
    field :batch_id, :string
    field :task_id, :string
    field :task_fingerprint, :string
    field :project_name, :string
    field :agent, :string
    field :model, :string
    field :adapter, :string
    field :state, :string
    field :verdict, :string
    field :agent_outcome_kind, :string
    field :duration_ms, :integer
    field :agent_diff_size, :integer
    field :reviewer_diff_size, :integer
    field :agent_exit_status, :integer
    field :review_iterations, :integer
    field :reviewer_reprompt_count, :integer
    field :reviewer_rotation_count, :integer
    field :reviewer_adapter, :string
    field :review_report, :binary
    field :reviewer_outcome_kind, :string
    field :reviewer_exit_status, :integer

    field :recovery_attempts, :integer
    field :recovery_outcome, :string
    field :recovery_repaired, :binary
    field :landed_sha, :string

    field :reason, :map
    field :token_usage, :map
    field :composed_inputs, :map
    field :review_facets, :map
    field :review_skills, :map
    field :review_ratings, :map
    field :domains, :map
    field :recovery_token_usage, :map

    field :agent_output, :binary
    field :reviewer_output, :binary

    # usec precision: inserted_at is the recency ordering key for
    # list_run_records (Task 139); second-precision ties are non-deterministic.
    timestamps(type: :naive_datetime_usec)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = struct, attrs) when is_map(attrs) do
    cast(struct, attrs, [
      :run_id,
      :batch_id,
      :task_id,
      :task_fingerprint,
      :project_name,
      :agent,
      :model,
      :adapter,
      :state,
      :verdict,
      :agent_outcome_kind,
      :duration_ms,
      :agent_diff_size,
      :reviewer_diff_size,
      :agent_exit_status,
      :review_iterations,
      :reviewer_reprompt_count,
      :reviewer_rotation_count,
      :reviewer_adapter,
      :review_report,
      :reviewer_outcome_kind,
      :reviewer_exit_status,
      :recovery_attempts,
      :recovery_outcome,
      :recovery_repaired,
      :landed_sha,
      :reason,
      :token_usage,
      :composed_inputs,
      :review_facets,
      :review_skills,
      :review_ratings,
      :domains,
      :recovery_token_usage,
      :agent_output,
      :reviewer_output
    ])
  end

  @type t :: %__MODULE__{}
end
