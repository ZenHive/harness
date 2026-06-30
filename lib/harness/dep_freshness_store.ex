defmodule Harness.DepFreshnessStore do
  @moduledoc """
  Pluggable persistence for per-project dependency freshness snapshots.

  Defaults follow `:repo_enabled`: Postgres when durable, in-memory ephemeral
  otherwise. Harness only stores and reads raw provider facts — no judgment.
  """

  alias Harness.DepFreshness.Snapshot

  @type store :: module() | {module(), keyword()} | false

  @doc "Persists the latest snapshot for a project, replacing any prior rows."
  @callback record_snapshot(Snapshot.t(), keyword()) :: :ok | {:error, term()}

  @doc "Fetches the latest snapshot for one project."
  @callback fetch_snapshot(String.t(), keyword()) :: {:ok, Snapshot.t()} | {:error, :not_found | term()}

  @doc "Lists the latest snapshot per project, optionally filtered by project name."
  @callback list_snapshots(keyword(), keyword()) :: {:ok, [Snapshot.t()]} | {:error, term()}

  @doc "Persists the latest snapshot for a project, replacing any prior rows."
  @spec record_snapshot(Snapshot.t(), store()) :: :ok | {:error, term()}
  def record_snapshot(%Snapshot{} = snapshot, store \\ configured()) do
    dispatch(store, :record_snapshot, [snapshot])
  end

  @doc "Fetches the latest snapshot for one project."
  @spec fetch_snapshot(String.t(), store()) :: {:ok, Snapshot.t()} | {:error, :not_found | term()}
  def fetch_snapshot(project_name, store \\ configured()) when is_binary(project_name) do
    dispatch(store, :fetch_snapshot, [project_name])
  end

  @doc "Lists the latest snapshot per project, optionally filtered by project name."
  @spec list_snapshots(keyword(), store()) :: {:ok, [Snapshot.t()]} | {:error, term()}
  def list_snapshots(filters \\ [], store \\ configured()) when is_list(filters) do
    dispatch(store, :list_snapshots, [filters])
  end

  @doc "Returns the configured backend."
  @spec configured() :: store()
  def configured do
    case Application.get_env(:harness, :dep_freshness_store) do
      nil ->
        if Application.get_env(:harness, :repo_enabled, true) do
          {Harness.DepFreshnessStore.Postgres, []}
        else
          {Harness.DepFreshnessStore.Memory, []}
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
