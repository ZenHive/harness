defmodule Harness.DepFreshness.Providers do
  @moduledoc false

  alias Harness.DepFreshness.Provider.Elixir, as: ElixirProvider
  alias Harness.Project

  @providers %{
    elixir: ElixirProvider
  }

  @doc "Resolves the freshness provider module for a project's language."
  @spec resolve(Project.t()) :: {:ok, module()} | {:skipped, term()}
  def resolve(%Project{} = project) do
    language = project.language || :elixir

    case Map.fetch(@providers, language) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:skipped, {:unsupported_language, language}}
    end
  end
end
