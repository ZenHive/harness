defmodule Harness.DependencyBump.Providers do
  @moduledoc false

  alias Harness.DependencyBump.Provider.Elixir, as: ElixirProvider
  alias Harness.DependencyBump.Provider.Go, as: GoProvider
  alias Harness.DependencyBump.Provider.JavaScript, as: JavaScriptProvider
  alias Harness.DependencyBump.Provider.Rust, as: RustProvider
  alias Harness.LanguageProviders
  alias Harness.Project

  @providers %{
    elixir: ElixirProvider,
    go: GoProvider,
    javascript: JavaScriptProvider,
    rust: RustProvider,
    typescript: JavaScriptProvider
  }

  @type resolution :: LanguageProviders.resolution()

  @doc "Resolves dependency-bump prompt providers for every project language."
  @spec resolve(Project.t()) :: [resolution()]
  def resolve(%Project{} = project) do
    project.languages
    |> LanguageProviders.resolve(@providers)
    |> Enum.uniq_by(&provider_key/1)
  end

  @spec provider_key(resolution()) :: term()
  defp provider_key({:ok, _language, provider}), do: provider
  defp provider_key({:skipped, language, _reason}), do: {:skipped, language}
end
