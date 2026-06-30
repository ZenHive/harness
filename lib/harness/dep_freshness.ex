defmodule Harness.DepFreshness do
  @moduledoc """
  Mechanical dependency-freshness fact capture for registered projects.

  Providers keyed on `project.language` produce raw rows; this module records
  them durably and exposes them to the dashboard. Harness never upgrades deps,
  never gates runs, and never judges which bumps matter.
  """

  alias Harness.DepFreshness.Providers
  alias Harness.DepFreshness.Snapshot
  alias Harness.DepFreshnessStore
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.ToolingBaseline

  require Logger

  @doc "Scans one project with its language provider and records the snapshot."
  @spec scan_project(Project.t(), keyword()) :: :ok | {:skipped, term()} | {:error, term()}
  def scan_project(%Project{} = project, opts \\ []) when is_list(opts) do
    store = Keyword.get(opts, :store, DepFreshnessStore.configured())
    provider_opts = Keyword.get(opts, :provider_opts, [])

    with {:ok, provider} <- Providers.resolve(project),
         {:ok, repo_path} <- repo_path(project),
         {:ok, rows} <- provider.scan(project, repo_path, provider_opts),
         language = language_label(project.language),
         conformance = scan_conformance(project, repo_path, provider_opts),
         snapshot = Snapshot.build(project.name, language, rows, conformance: conformance),
         :ok <- DepFreshnessStore.record_snapshot(snapshot, store) do
      :ok
    else
      {:skipped, reason} = skipped ->
        Logger.debug("harness dep freshness: skipped #{project.name}: #{inspect(reason)}")
        skipped

      {:error, reason} = error ->
        Logger.warning("harness dep freshness: failed #{project.name}: #{inspect(reason)}")
        error
    end
  end

  @doc "Scans every registered project whose language has a provider."
  @spec scan_all(keyword()) :: :ok
  def scan_all(opts \\ []) when is_list(opts) do
    Enum.each(ProjectRegistry.list(), &scan_project(&1, opts))
    :ok
  end

  @doc "Lists stored snapshots, optionally filtered by project name."
  @spec list_snapshots(keyword()) :: {:ok, [Snapshot.t()]} | {:error, term()}
  def list_snapshots(opts \\ []) when is_list(opts) do
    filters =
      opts
      |> Keyword.take([:project_name])
      |> Enum.to_list()

    DepFreshnessStore.list_snapshots(filters, Keyword.get(opts, :store, DepFreshnessStore.configured()))
  end

  @doc "Fetches one project's latest snapshot."
  @spec fetch_snapshot(String.t(), keyword()) :: {:ok, Snapshot.t()} | {:error, :not_found | term()}
  def fetch_snapshot(project_name, opts \\ []) when is_binary(project_name) do
    DepFreshnessStore.fetch_snapshot(project_name, Keyword.get(opts, :store, DepFreshnessStore.configured()))
  end

  @spec repo_path(Project.t()) :: {:ok, String.t()} | {:skipped, term()}
  defp repo_path(%Project{} = project) do
    case Project.local_repo_path(project) do
      {:ok, path} -> {:ok, path}
      {:skipped, _} = skipped -> skipped
    end
  end

  @spec language_label(atom() | nil) :: String.t()
  defp language_label(nil), do: "elixir"
  defp language_label(language) when is_atom(language), do: Atom.to_string(language)

  @spec scan_conformance(Project.t(), String.t(), keyword()) ::
          Harness.ToolingBaseline.Snapshot.t() | nil
  defp scan_conformance(%Project{language: :elixir} = project, repo_path, provider_opts) do
    case ToolingBaseline.scan_project(project, repo_path, provider_opts: provider_opts) do
      {:ok, snapshot} -> snapshot
      _other -> nil
    end
  end

  defp scan_conformance(_project, _repo_path, _provider_opts), do: nil
end
