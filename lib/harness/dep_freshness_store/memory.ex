defmodule Harness.DepFreshnessStore.Memory do
  @moduledoc false

  @behaviour Harness.DepFreshnessStore

  alias Harness.DepFreshness.Snapshot
  alias Harness.Store.EtsScope

  @table __MODULE__

  @impl Harness.DepFreshnessStore
  @spec record_snapshot(Snapshot.t(), keyword()) :: :ok
  def record_snapshot(%Snapshot{} = snapshot, opts) when is_list(opts) do
    EtsScope.update(@table, opts, empty_state(), fn state ->
      %{state | snapshots: Map.put(state.snapshots, snapshot.project_name, snapshot)}
    end)
  end

  @impl Harness.DepFreshnessStore
  @spec fetch_snapshot(String.t(), keyword()) :: {:ok, Snapshot.t()} | {:error, :not_found}
  def fetch_snapshot(project_name, opts) when is_binary(project_name) and is_list(opts) do
    case Map.fetch(read(opts).snapshots, project_name) do
      {:ok, %Snapshot{} = snapshot} -> {:ok, snapshot}
      :error -> {:error, :not_found}
    end
  end

  @impl Harness.DepFreshnessStore
  @spec list_snapshots(keyword(), keyword()) :: {:ok, [Snapshot.t()]}
  def list_snapshots(filters, opts) when is_list(filters) and is_list(opts) do
    project_name = Keyword.get(filters, :project_name)

    snapshots =
      read(opts).snapshots
      |> Map.values()
      |> maybe_filter_project(project_name)
      |> Enum.sort_by(& &1.project_name)

    {:ok, snapshots}
  end

  @spec read(keyword()) :: map()
  defp read(opts), do: EtsScope.read(@table, opts, empty_state())

  @spec empty_state() :: %{snapshots: %{String.t() => Snapshot.t()}}
  defp empty_state, do: %{snapshots: %{}}

  @spec maybe_filter_project([Snapshot.t()], String.t() | nil) :: [Snapshot.t()]
  defp maybe_filter_project(snapshots, nil), do: snapshots

  defp maybe_filter_project(snapshots, project_name) do
    Enum.filter(snapshots, &(&1.project_name == project_name))
  end
end
