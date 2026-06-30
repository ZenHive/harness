defmodule Harness.DepFreshness.Providers do
  @moduledoc false

  alias Harness.DepFreshness.Provider.Elixir, as: ElixirProvider
  alias Harness.Project

  @providers %{
    elixir: ElixirProvider
  }

  @type resolution :: {:ok, atom(), module()} | {:skipped, atom(), term()}

  @doc "Resolves freshness provider modules for every project language."
  @spec resolve(Project.t()) :: [resolution()]
  def resolve(%Project{} = project) do
    Enum.map(project.languages, &resolve_language/1)
  end

  @spec resolve_language(atom()) :: resolution()
  defp resolve_language(language) do
    case Map.fetch(@providers, language) do
      {:ok, provider} -> {:ok, language, provider}
      :error -> {:skipped, language, {:unsupported_language, language}}
    end
  end
end
