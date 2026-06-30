defmodule Harness.DepFreshness.Providers do
  @moduledoc false

  alias Harness.DepFreshness.Provider.Elixir, as: ElixirProvider
  alias Harness.LanguageProviders
  alias Harness.Project

  @providers %{
    elixir: ElixirProvider
  }

  @type resolution :: LanguageProviders.resolution()

  @doc "Resolves freshness provider modules for every project language."
  @spec resolve(Project.t()) :: [resolution()]
  def resolve(%Project{} = project) do
    LanguageProviders.resolve(project.languages, @providers)
  end
end
