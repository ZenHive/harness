defmodule Harness.SuiteHealth.Commands do
  @moduledoc false

  alias Harness.LanguageProviders
  alias Harness.Project
  alias Harness.SuiteHealth.Commands.JavaScript

  @providers %{
    elixir: Harness.SuiteHealth.Commands.Elixir,
    rust: Harness.SuiteHealth.Commands.Rust,
    go: Harness.SuiteHealth.Commands.Go,
    javascript: JavaScript,
    typescript: JavaScript
  }

  @type command :: {String.t(), [String.t()]}
  @type resolution :: {:ok, atom(), command()} | {:skipped, atom(), term()}

  @doc "Resolves one full-suite command module per project language."
  @spec resolve(Project.t()) :: [resolution()]
  def resolve(%Project{} = project) do
    LanguageProviders.resolve(project.languages, @providers)
  end
end
