defmodule Harness.DepFreshness.Snapshot do
  @moduledoc """
  Latest dependency-freshness facts for one registered project.
  """

  alias Harness.DepFreshness.Row

  @enforce_keys [:project_name, :language, :checked_at, :outdated_count, :rows]
  defstruct [:project_name, :language, :checked_at, :outdated_count, rows: []]

  @type t :: %__MODULE__{
          project_name: String.t(),
          language: String.t(),
          checked_at: DateTime.t(),
          outdated_count: non_neg_integer(),
          rows: [Row.t()]
        }

  @doc "Counts rows whose current version differs from the latest reported version."
  @spec outdated_count([Row.t()]) :: non_neg_integer()
  def outdated_count(rows) when is_list(rows) do
    Enum.count(rows, &Row.outdated?/1)
  end

  @doc "Builds a snapshot from provider rows, stamping `checked_at` mechanically."
  @spec build(String.t(), String.t(), [Row.t()], DateTime.t()) :: t()
  def build(project_name, language, rows, checked_at \\ DateTime.utc_now(:millisecond))
      when is_binary(project_name) and is_binary(language) and is_list(rows) do
    %__MODULE__{
      project_name: project_name,
      language: language,
      checked_at: checked_at,
      outdated_count: outdated_count(rows),
      rows: rows
    }
  end
end
