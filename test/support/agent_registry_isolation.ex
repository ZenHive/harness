defmodule Harness.Test.AgentRegistryIsolation do
  @moduledoc """
  Isolates the AgentRegistry singleton and the SettingsStore keys it can poison.

  `AgentRegistry.reset/0` clears only GenServer `unavailable`/`installed` maps.
  `mark_unavailable/2` also persists ModelAvailability blocks (and tests seed
  catalogs) into SettingsStore. Those keys survive reset and later make
  `select_resolver_candidate/2` return `{:unavailable, _, _, available: []}`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Harness.AgentRegistry
  alias Harness.SettingsStore

  @store_keys [:model_blocks, :model_catalogs, :model_catalog_static, :model_catalog_manual]

  @doc """
  ExUnit setup callback: clear dispatch state at test start and again on exit.
  """
  @spec isolate(map()) :: :ok
  def isolate(_context) do
    reset_dispatch_state()
    on_exit(&reset_dispatch_state/0)
    :ok
  end

  @doc """
  Clears AgentRegistry GenServer state and persisted model-availability keys.
  """
  @spec reset_dispatch_state() :: :ok
  def reset_dispatch_state do
    AgentRegistry.reset()
    Enum.each(@store_keys, &SettingsStore.put(&1, %{}))
    :ok
  end
end
