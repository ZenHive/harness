defmodule Harness.ToolingBaseline do
  @moduledoc """
  Mechanical tooling-baseline conformance fact capture for registered projects.

  Providers keyed on `project.languages` compare committed project surface against
  harness-shipped manifests; this module records raw drift facts for the
  dashboard. Harness never installs tooling, never mutates projects, and never
  gates dispatch on conformance.
  """

  alias Harness.Project
  alias Harness.ToolingBaseline.Item
  alias Harness.ToolingBaseline.Providers
  alias Harness.ToolingBaseline.Snapshot

  require Logger

  @doc "Scans one project with its language baseline providers."
  @spec scan_project(Project.t(), String.t(), keyword()) :: {:ok, Snapshot.t()} | {:skipped, term()} | {:error, term()}
  def scan_project(%Project{} = project, repo_path, opts \\ []) when is_binary(repo_path) and is_list(opts) do
    provider_opts = Keyword.get(opts, :provider_opts, [])

    case scan_providers(project, repo_path, provider_opts) do
      {:ok, snapshot} ->
        {:ok, snapshot}

      {:error, reason} = error ->
        Logger.warning("harness tooling baseline: failed #{project.name}: #{inspect(reason)}")
        error
    end
  end

  @spec scan_providers(Project.t(), String.t(), keyword()) :: {:ok, Snapshot.t()} | {:error, term()}
  defp scan_providers(%Project{} = project, repo_path, provider_opts) do
    project
    |> Providers.resolve()
    |> Enum.reduce({[], [], []}, fn
      {:ok, language, provider}, {items, advisory, errors} ->
        case provider.scan(project, repo_path, provider_opts) do
          {:ok, %Snapshot{} = snapshot} ->
            {items ++ snapshot.items, advisory ++ snapshot.advisory, errors}

          {:skipped, reason} ->
            Logger.debug("harness tooling baseline: skipped #{project.name}: #{inspect({language, reason})}")
            {items ++ [Item.skipped(language, reason)], advisory, errors}

          {:error, reason} ->
            {items ++ [Item.skipped(language, reason)], advisory, [{language, reason} | errors]}
        end

      {:skipped, language, reason}, {items, advisory, errors} ->
        Logger.debug("harness tooling baseline: skipped #{project.name}: #{inspect({language, reason})}")
        {items ++ [Item.skipped(language, reason)], advisory, errors}
    end)
    |> scan_result()
  end

  @spec scan_result({[Item.t()], [term()], [{atom(), term()}]}) ::
          {:ok, Snapshot.t()} | {:error, term()}
  defp scan_result({items, advisory, []}) do
    {:ok, Snapshot.build(items, advisory)}
  end

  defp scan_result({_items, _advisory, errors}) do
    {:error, {:provider_errors, Enum.reverse(errors)}}
  end
end
