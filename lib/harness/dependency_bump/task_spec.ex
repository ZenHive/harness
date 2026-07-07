defmodule Harness.DependencyBump.TaskSpec do
  @moduledoc """
  Roadmap task payload for an operator-triggered dependency bump.
  """

  alias Harness.DepFreshness.Row

  @enforce_keys [
    :language,
    :kind,
    :title,
    :body,
    :acceptance_criteria,
    :files_to_modify,
    :check_command,
    :rows
  ]
  defstruct [
    :language,
    :kind,
    :title,
    :body,
    :acceptance_criteria,
    :files_to_modify,
    :check_command,
    rows: []
  ]

  @type kind :: :minor_patch | :major

  @type t :: %__MODULE__{
          language: atom(),
          kind: kind(),
          title: String.t(),
          body: String.t(),
          acceptance_criteria: [String.t()],
          files_to_modify: [String.t()],
          check_command: String.t(),
          rows: [Row.t()]
        }
end
