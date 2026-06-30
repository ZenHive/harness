defmodule Harness.ToolingBaseline.Providers do
  @moduledoc false

  alias Harness.Project
  alias Harness.ToolingBaseline.Provider.Elixir, as: ElixirProvider

  @providers %{
    elixir: ElixirProvider
  }

  @doc "Resolves the baseline provider module for a project's language."
  @spec resolve(Project.t()) :: {:ok, module()} | {:skipped, term()}
  def resolve(%Project{} = project) do
    case Map.fetch(@providers, project.language) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:skipped, {:unsupported_language, project.language}}
    end
  end
end
