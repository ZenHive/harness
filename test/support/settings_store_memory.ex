defmodule Harness.Test.SettingsStoreMemory do
  @moduledoc """
  In-memory `Harness.SettingsStore` backend for tests.

  Production has exactly two backends — Postgres (`repo_enabled: true`) and the
  ephemeral no-op store (`repo_enabled: false`). This test-only backend gives the
  suite a *persistent* (within the BEAM) store so a flip survives a simulated
  restart without a live database, mirroring `Harness.ResultStore.Memory`. It is
  ETS-backed and scope-keyed; `reset/1` clears a scope between tests.

  Tests can scope the store with an arbitrary atom so each case starts from an
  empty persistence surface.
  """

  @behaviour Harness.SettingsStore

  alias Harness.SettingsStore

  @table __MODULE__

  @impl SettingsStore
  @spec fetch(String.t(), keyword()) :: {:ok, term()} | :not_found
  def fetch(key, backend_opts) when is_binary(key) and is_list(backend_opts) do
    case Map.fetch(read(backend_opts), key) do
      {:ok, value} -> {:ok, value}
      :error -> :not_found
    end
  end

  @impl SettingsStore
  @spec put(String.t(), term(), keyword()) :: :ok
  def put(key, value, backend_opts) when is_binary(key) and is_list(backend_opts) do
    ensure_table()
    :ets.insert(@table, {scope(backend_opts), Map.put(read(backend_opts), key, value)})
    :ok
  end

  @doc "Clears the scope so a test starts from an empty store."
  @spec reset(keyword()) :: :ok
  def reset(backend_opts \\ []) when is_list(backend_opts) do
    ensure_table()
    :ets.delete(@table, scope(backend_opts))
    SettingsStore.reset_cache()
    :ok
  end

  @spec read(keyword()) :: %{String.t() => term()}
  defp read(backend_opts) do
    ensure_table()

    case :ets.lookup(@table, scope(backend_opts)) do
      [{_scope, map}] -> map
      [] -> %{}
    end
  end

  @spec ensure_table() :: :ok
  defp ensure_table do
    _ = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec scope(keyword()) :: term()
  defp scope(backend_opts), do: Keyword.get(backend_opts, :scope, :default)
end
