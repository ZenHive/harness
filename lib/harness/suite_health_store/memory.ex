defmodule Harness.SuiteHealthStore.Memory do
  @moduledoc false

  @behaviour Harness.SuiteHealthStore

  alias Harness.Store.EtsScope
  alias Harness.SuiteHealth.Result

  @table __MODULE__

  @impl Harness.SuiteHealthStore
  @spec record_result(Result.t(), keyword()) :: :ok
  def record_result(%Result{} = result, opts) when is_list(opts) do
    EtsScope.update(@table, opts, empty_state(), fn state ->
      %{state | results: Map.put(state.results, result.project_name, result)}
    end)
  end

  @impl Harness.SuiteHealthStore
  @spec fetch_result(String.t(), keyword()) :: {:ok, Result.t()} | {:error, :not_found}
  def fetch_result(project_name, opts) when is_binary(project_name) and is_list(opts) do
    case Map.fetch(read(opts).results, project_name) do
      {:ok, %Result{} = result} -> {:ok, result}
      :error -> {:error, :not_found}
    end
  end

  @impl Harness.SuiteHealthStore
  @spec list_results(keyword(), keyword()) :: {:ok, [Result.t()]}
  def list_results(filters, opts) when is_list(filters) and is_list(opts) do
    project_name = Keyword.get(filters, :project_name)

    results =
      read(opts).results
      |> Map.values()
      |> maybe_filter_project(project_name)
      |> Enum.sort_by(& &1.project_name)

    {:ok, results}
  end

  @spec read(keyword()) :: map()
  defp read(opts), do: EtsScope.read(@table, opts, empty_state())

  @spec empty_state() :: %{results: %{String.t() => Result.t()}}
  defp empty_state, do: %{results: %{}}

  @spec maybe_filter_project([Result.t()], String.t() | nil) :: [Result.t()]
  defp maybe_filter_project(results, nil), do: results

  defp maybe_filter_project(results, project_name) do
    Enum.filter(results, &(&1.project_name == project_name))
  end
end
