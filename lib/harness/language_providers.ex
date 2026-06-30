defmodule Harness.LanguageProviders do
  @moduledoc false

  @type resolution :: {:ok, atom(), module()} | {:skipped, atom(), term()}

  @doc "Maps each language atom to a provider module or a skipped unsupported fact."
  @spec resolve([atom()], %{atom() => module()}) :: [resolution()]
  def resolve(languages, providers) when is_list(languages) and is_map(providers) do
    Enum.map(languages, &resolve_language(&1, providers))
  end

  @spec resolve_language(atom(), %{atom() => module()}) :: resolution()
  defp resolve_language(language, providers) do
    case Map.fetch(providers, language) do
      {:ok, provider} -> {:ok, language, provider}
      :error -> {:skipped, language, {:unsupported_language, language}}
    end
  end
end
