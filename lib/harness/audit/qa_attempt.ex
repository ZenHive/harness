defmodule Harness.Audit.QAAttempt do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "audit_qa_attempts" do
    field :project_name, :string
    field :target_branch, :string
    field :base_sha, :string
    field :revision, :string
    field :command, :string
    field :status, :string
    field :agent, :string
    field :model, :string
    field :job_id, :integer
    field :attempt, :integer
    field :landing_shas, {:array, :string}, default: []
    field :report, :map, default: %{}
    field :transcript, :string
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
