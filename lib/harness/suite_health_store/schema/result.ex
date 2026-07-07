defmodule Harness.SuiteHealthStore.Schema.Result do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:project_name, :string, autogenerate: false}
  schema "suite_health_results" do
    field :checked_at, :utc_datetime_usec
    field :passed, :boolean
    field :exit_code, :integer
    field :command, :string
    field :base_sha, :string
    field :skip_reason, :string
    field :failing_tests, {:array, :map}, default: []
    field :languages, :string

    timestamps()
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = result, attrs) do
    result
    |> cast(attrs, [
      :project_name,
      :checked_at,
      :passed,
      :exit_code,
      :command,
      :base_sha,
      :skip_reason,
      :failing_tests,
      :languages
    ])
    |> validate_required([:project_name, :checked_at, :failing_tests, :languages])
  end

  @type t :: %__MODULE__{}
end
