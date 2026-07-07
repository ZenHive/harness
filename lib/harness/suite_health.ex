defmodule Harness.SuiteHealth do
  @moduledoc """
  Scheduled full-suite health-check witness for registered projects.

  Runs language-derived suite commands (including integration tests) in a cold
  detached worktree at `origin/<target>` HEAD, records pass/fail + failing tests
  + exit code + timestamp, and surfaces the raw facts in the dashboard. Harness
  never gates, blocks, routes, or classifies on these results.
  """

  alias Harness.Git
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.SuiteHealth.Result
  alias Harness.SuiteHealth.Runner
  alias Harness.SuiteHealthStore
  alias Harness.Worktree

  require Logger

  @doc "Checks one project and records the witness fact."
  @spec check_project(Project.t(), keyword()) :: :ok | {:error, term()}
  def check_project(%Project{} = project, opts \\ []) when is_list(opts) do
    store = Keyword.get(opts, :store, SuiteHealthStore.configured())

    case checkout_cold(project, opts) do
      {:ok, worktree} ->
        result = suite_result(project, worktree, opts)
        _ = cleanup(worktree)
        persist_result(result, store)

      {:skipped, reason} ->
        persist_skipped(project, reason, store)

      {:error, reason} = error ->
        Logger.warning("harness suite health: failed #{project.name}: #{inspect(reason)}")
        error
    end
  end

  @spec suite_result(Project.t(), Worktree.t(), keyword()) :: Result.t()
  defp suite_result(%Project{} = project, %Worktree{} = worktree, opts) do
    case Runner.run_suite(project, worktree.path, worktree.base_sha, opts) do
      {:ok, %Result{} = result} -> result
      {:error, reason} -> Result.skipped(project.name, inspect(reason), languages: language_label(project.languages))
    end
  end

  @spec persist_skipped(Project.t(), term(), SuiteHealthStore.store()) :: :ok | {:error, term()}
  defp persist_skipped(%Project{name: name} = project, reason, store) do
    name
    |> Result.skipped(inspect(reason), languages: language_label(project.languages))
    |> persist_result(store)
  end

  @spec persist_result(Result.t(), SuiteHealthStore.store()) :: :ok | {:error, term()}
  defp persist_result(%Result{} = result, store) do
    case SuiteHealthStore.record_result(result, store) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning("harness suite health: failed to persist #{result.project_name}: #{inspect(reason)}")
        error
    end
  end

  @doc "Checks every registered project."
  @spec check_all(keyword()) :: :ok
  def check_all(opts \\ []) when is_list(opts) do
    Enum.each(ProjectRegistry.list(), fn project ->
      case check_project(project, opts) do
        :ok -> :ok
        {:error, _reason} -> :ok
      end
    end)

    :ok
  end

  @doc "Lists stored witness facts, optionally filtered by project name."
  @spec list_results(keyword()) :: {:ok, [Result.t()]} | {:error, term()}
  def list_results(opts \\ []) when is_list(opts) do
    filters =
      opts
      |> Keyword.take([:project_name])
      |> Enum.to_list()

    SuiteHealthStore.list_results(filters, Keyword.get(opts, :store, SuiteHealthStore.configured()))
  end

  @doc "Fetches one project's latest witness fact."
  @spec fetch_result(String.t(), keyword()) :: {:ok, Result.t()} | {:error, :not_found | term()}
  def fetch_result(project_name, opts \\ []) when is_binary(project_name) do
    SuiteHealthStore.fetch_result(project_name, Keyword.get(opts, :store, SuiteHealthStore.configured()))
  end

  @spec checkout_cold(Project.t(), keyword()) ::
          {:ok, Worktree.t()} | {:skipped, term()} | {:error, term()}
  defp checkout_cold(%Project{} = project, opts) do
    with {:ok, repo} <- Project.local_repo_path(project),
         {:ok, target} <- target_branch(project),
         :ok <- fetch_origin(repo) do
      checkout(repo, target, opts)
    end
  end

  @spec checkout(String.t(), String.t(), keyword()) :: {:ok, Worktree.t()} | {:error, term()}
  defp checkout(repo, target, opts) do
    id = Keyword.get(opts, :worktree_id, "health-#{System.unique_integer([:positive])}")

    checkout_opts =
      then([id: id], fn kw ->
        case Keyword.get(opts, :worktree_path) do
          path when is_binary(path) -> Keyword.put(kw, :path, path)
          nil -> kw
        end
      end)

    case Worktree.checkout_existing(repo, "origin/" <> target, checkout_opts) do
      {:ok, worktree} -> {:ok, worktree}
      {:error, reason} -> {:error, {:checkout_failed, reason}}
    end
  end

  @spec target_branch(Project.t()) :: {:ok, String.t()} | {:skipped, :no_target_branch}
  defp target_branch(%Project{target_branch: tb}) when is_binary(tb) and tb != "", do: {:ok, tb}
  defp target_branch(%Project{}), do: {:skipped, :no_target_branch}

  @spec fetch_origin(String.t()) :: :ok | {:error, term()}
  defp fetch_origin(repo) do
    case Git.run(["fetch", "origin"], repo) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:fetch_failed, reason}}
    end
  end

  @spec cleanup(Worktree.t()) :: :ok
  defp cleanup(%Worktree{} = worktree) do
    case Worktree.remove(worktree) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("harness suite health: failed to remove worktree #{worktree.path}: #{inspect(reason)}")
        :ok
    end
  end

  @spec language_label([atom()]) :: String.t()
  defp language_label(languages), do: Enum.map_join(languages, ",", &Atom.to_string/1)
end
