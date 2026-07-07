defmodule Harness.SuiteHealthStore do
  @moduledoc """
  Pluggable persistence for per-project full-suite health-check witness facts.

  Defaults follow `:repo_enabled`: Postgres when durable, in-memory ephemeral
  otherwise. Harness only stores and reads raw facts — no judgment.
  """

  alias Harness.Store
  alias Harness.SuiteHealth.Result

  @type store :: Store.store()

  @doc "Persists the latest witness for a project, replacing any prior row."
  @callback record_result(Result.t(), keyword()) :: :ok | {:error, term()}

  @doc "Fetches the latest witness for one project."
  @callback fetch_result(String.t(), keyword()) :: {:ok, Result.t()} | {:error, :not_found | term()}

  @doc "Lists the latest witness per project, optionally filtered by project name."
  @callback list_results(keyword(), keyword()) :: {:ok, [Result.t()]} | {:error, term()}

  @doc "Persists the latest witness for a project, replacing any prior row."
  @spec record_result(Result.t(), store()) :: :ok | {:error, term()}
  def record_result(%Result{} = result, store \\ configured()) do
    Store.dispatch(store, :record_result, [result])
  end

  @doc "Fetches the latest witness for one project."
  @spec fetch_result(String.t(), store()) :: {:ok, Result.t()} | {:error, :not_found | term()}
  def fetch_result(project_name, store \\ configured()) when is_binary(project_name) do
    Store.dispatch(store, :fetch_result, [project_name])
  end

  @doc "Lists the latest witness per project, optionally filtered by project name."
  @spec list_results(keyword(), store()) :: {:ok, [Result.t()]} | {:error, term()}
  def list_results(filters \\ [], store \\ configured()) when is_list(filters) do
    Store.dispatch(store, :list_results, [filters])
  end

  @doc "Returns the configured backend."
  @spec configured() :: store()
  def configured do
    case Application.get_env(:harness, :suite_health_store) do
      nil ->
        if Application.get_env(:harness, :repo_enabled, true) do
          {Harness.SuiteHealthStore.Postgres, []}
        else
          {Harness.SuiteHealthStore.Memory, []}
        end

      store ->
        store
    end
  end
end
