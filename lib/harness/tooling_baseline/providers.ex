defmodule Harness.ToolingBaseline.Providers do
  @moduledoc false

  alias Harness.LanguageProviders
  alias Harness.Project
  alias Harness.ToolingBaseline.Provider.Elixir, as: ElixirProvider

  @providers %{
    elixir: ElixirProvider
  }

  @type resolution :: LanguageProviders.resolution()

  @doc "Resolves baseline provider modules for every project language."
  @spec resolve(Project.t()) :: [resolution()]
  def resolve(%Project{} = project) do
    LanguageProviders.resolve(project.languages, @providers)
  end
end
