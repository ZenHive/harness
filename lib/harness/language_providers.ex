defmodule Harness.LanguageProviders do
  @moduledoc false

  @type resolution :: {:ok, atom(), module()} | {:skipped, atom(), term()}

  @doc false
  defmacro __using__(opts) do
    providers = Keyword.fetch!(opts, :providers)

    quote do
      alias Harness.LanguageProviders
      alias Harness.Project

      @type resolution :: LanguageProviders.resolution()

      @doc "Resolves this subsystem's provider module for every project language."
      @spec resolve(Project.t()) :: [resolution()]
      def resolve(%Project{} = project) do
        LanguageProviders.resolve_uniq(project.languages, unquote(providers))
      end
    end
  end

  @doc "Maps each language atom to a provider module or a skipped unsupported fact."
  @spec resolve([atom()], %{atom() => module()}) :: [resolution()]
  def resolve(languages, providers) when is_list(languages) and is_map(providers) do
    Enum.map(languages, &resolve_language(&1, providers))
  end

  @doc "Resolves languages to provider modules, collapsing languages that share a module."
  @spec resolve_uniq([atom()], %{atom() => module()}) :: [resolution()]
  def resolve_uniq(languages, providers) when is_list(languages) and is_map(providers) do
    languages
    |> resolve(providers)
    |> Enum.uniq_by(&provider_key/1)
  end

  @spec provider_key(resolution()) :: term()
  defp provider_key({:ok, _language, provider}), do: provider
  defp provider_key({:skipped, language, _reason}), do: {:skipped, language}

  @spec resolve_language(atom(), %{atom() => module()}) :: resolution()
  defp resolve_language(language, providers) do
    case Map.fetch(providers, language) do
      {:ok, provider} -> {:ok, language, provider}
      :error -> {:skipped, language, {:unsupported_language, language}}
    end
  end
end
