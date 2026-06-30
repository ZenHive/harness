defmodule Harness.DepFreshness do
  @moduledoc """
  Mechanical dependency-freshness fact capture for registered projects.

  Providers keyed on `project.languages` produce raw rows; this module records
  them durably and exposes them to the dashboard. Harness never upgrades deps,
  never gates runs, and never judges which bumps matter.
  """

  alias Harness.DepFreshness.Providers
  alias Harness.DepFreshness.Row
  alias Harness.DepFreshness.Snapshot
  alias Harness.DepFreshnessStore
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.ToolingBaseline
  alias Harness.ToolingBaseline.Snapshot, as: ConformanceSnapshot

  require Logger

  @doc "Scans one project with its language providers and records the snapshot."
  @spec scan_project(Project.t(), keyword()) :: :ok | {:skipped, term()} | {:error, term()}
  def scan_project(%Project{} = project, opts \\ []) when is_list(opts) do
    store = Keyword.get(opts, :store, DepFreshnessStore.configured())
    provider_opts = Keyword.get(opts, :provider_opts, [])

    case repo_path(project) do
      {:ok, repo_path} ->
        conformance = scan_conformance(project, repo_path, provider_opts)

        project
        |> scan_freshness(repo_path, provider_opts)
        |> record_scan_result(project, conformance, store)

      {:skipped, reason} = skipped ->
        Logger.debug("harness dep freshness: skipped #{project.name}: #{inspect(reason)}")
        skipped
    end
  end

  @doc "Scans every registered project with visible provider facts per language."
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

  @spec language_label(nonempty_list(atom())) :: String.t()
  defp language_label(languages), do: Enum.map_join(languages, ",", &Atom.to_string/1)

  @spec scan_freshness(Project.t(), String.t(), keyword()) ::
          {:ok, [Row.t()]} | {:error, {term(), [Row.t()]}}
  defp scan_freshness(%Project{} = project, repo_path, provider_opts) do
    project
    |> Providers.resolve()
    |> Enum.reduce({[], []}, fn
      {:ok, language, provider}, {rows, errors} ->
        case provider.scan(project, repo_path, provider_opts) do
          {:ok, provider_rows} -> {tag_rows(provider_rows, language) ++ rows, errors}
          {:skipped, reason} -> {[Row.skipped(language, reason) | rows], errors}
          {:error, reason} -> {[Row.skipped(language, reason) | rows], [{language, reason} | errors]}
        end

      {:skipped, language, reason}, {rows, errors} ->
        {[Row.skipped(language, reason) | rows], errors}
    end)
    |> scan_result()
  end

  @spec tag_rows([Row.t()], atom()) :: [Row.t()]
  defp tag_rows(rows, language), do: Enum.map(rows, &%{&1 | language: language})

  @spec scan_result({[Row.t()], [{atom(), term()}]}) :: {:ok, [Row.t()]} | {:error, {term(), [Row.t()]}}
  defp scan_result({rows, []}), do: {:ok, Enum.reverse(rows)}
  defp scan_result({rows, errors}), do: {:error, {{:provider_errors, Enum.reverse(errors)}, Enum.reverse(rows)}}

  @spec record_scan_result(
          {:ok, [Row.t()]} | {:error, {term(), [Row.t()]}},
          Project.t(),
          ConformanceSnapshot.t() | nil,
          keyword()
        ) :: :ok | {:skipped, term()} | {:error, term()}
  defp record_scan_result({:ok, rows}, %Project{} = project, conformance, store) do
    project
    |> build_snapshot(rows, conformance)
    |> DepFreshnessStore.record_snapshot(store)
  end

  defp record_scan_result({:error, {reason, rows}}, %Project{} = project, %ConformanceSnapshot{} = conformance, store) do
    Logger.warning("harness dep freshness: failed #{project.name}: #{inspect(reason)}")

    case project |> build_snapshot(rows, conformance) |> DepFreshnessStore.record_snapshot(store) do
      :ok -> {:error, reason}
      {:error, _reason} = store_error -> store_error
    end
  end

  defp record_scan_result({:error, {reason, _rows}}, %Project{} = project, _conformance, _store) do
    Logger.warning("harness dep freshness: failed #{project.name}: #{inspect(reason)}")
    {:error, reason}
  end

  @spec build_snapshot(Project.t(), [Row.t()], ConformanceSnapshot.t() | nil) :: Snapshot.t()
  defp build_snapshot(%Project{} = project, rows, conformance) do
    Snapshot.build(project.name, language_label(project.languages), rows, conformance: conformance)
  end

  @spec scan_conformance(Project.t(), String.t(), keyword()) ::
          ConformanceSnapshot.t() | nil
  defp scan_conformance(%Project{languages: languages} = project, repo_path, provider_opts) do
    if :elixir in languages do
      scan_elixir_conformance(project, repo_path, provider_opts)
    end
  end

  @spec scan_elixir_conformance(Project.t(), String.t(), keyword()) :: ConformanceSnapshot.t() | nil
  defp scan_elixir_conformance(%Project{} = project, repo_path, provider_opts) do
    case ToolingBaseline.scan_project(project, repo_path, provider_opts: provider_opts) do
      {:ok, snapshot} -> snapshot
      _other -> nil
    end
  end
end
