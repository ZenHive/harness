defmodule Harness.SuiteHealthStore do
  @moduledoc """
  Pluggable persistence for per-project full-suite health-check witness facts.

  Defaults follow `:repo_enabled`: Postgres when durable, in-memory ephemeral
  otherwise. Harness only stores and reads raw facts — no judgment.
  """

  alias Harness.SuiteHealth.Result

  @type store :: module() | {module(), keyword()} | false

  @doc "Persists the latest witness for a project, replacing any prior row."
  @callback record_result(Result.t(), keyword()) :: :ok | {:error, term()}

  @doc "Fetches the latest witness for one project."
  @callback fetch_result(String.t(), keyword()) :: {:ok, Result.t()} | {:error, :not_found | term()}

  @doc "Lists the latest witness per project, optionally filtered by project name."
  @callback list_results(keyword(), keyword()) :: {:ok, [Result.t()]} | {:error, term()}

  @doc "Persists the latest witness for a project, replacing any prior row."
  @spec record_result(Result.t(), store()) :: :ok | {:error, term()}
  def record_result(%Result{} = result, store \\ configured()) do
    dispatch(store, :record_result, [result])
  end

  @doc "Fetches the latest witness for one project."
  @spec fetch_result(String.t(), store()) :: {:ok, Result.t()} | {:error, :not_found | term()}
  def fetch_result(project_name, store \\ configured()) when is_binary(project_name) do
    dispatch(store, :fetch_result, [project_name])
  end

  @doc "Lists the latest witness per project, optionally filtered by project name."
  @spec list_results(keyword(), store()) :: {:ok, [Result.t()]} | {:error, term()}
  def list_results(filters \\ [], store \\ configured()) when is_list(filters) do
    dispatch(store, :list_results, [filters])
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

  @spec dispatch(store(), atom(), [term()]) :: term()
  defp dispatch(false, _function, _args), do: :ok

  defp dispatch({module, opts}, function, args) when is_atom(module) and is_list(opts) do
    apply(module, function, args ++ [opts])
  end

  defp dispatch(module, function, args) when is_atom(module) do
    apply(module, function, args ++ [[]])
  end
end
