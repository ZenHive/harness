defmodule Harness.ToolingBaseline.TaskSpec do
  @moduledoc """
  Roadmap task payload for an operator-triggered tooling-baseline install.
  """

  alias Harness.ToolingBaseline.Item

  @enforce_keys [
    :language,
    :kind,
    :title,
    :body,
    :acceptance_criteria,
    :files_to_modify,
    :check_command,
    :items
  ]
  defstruct [
    :language,
    :kind,
    :title,
    :body,
    :acceptance_criteria,
    :files_to_modify,
    :check_command,
    items: [],
    skipped_languages: []
  ]

  @type skipped_language :: %{language: atom(), reason: term()}

  @type t :: %__MODULE__{
          language: atom(),
          kind: :tooling_baseline,
          title: String.t(),
          body: String.t(),
          acceptance_criteria: [String.t()],
          files_to_modify: [String.t()],
          check_command: String.t(),
          items: [Item.t()],
          skipped_languages: [skipped_language()]
        }
end
