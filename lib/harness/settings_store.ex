defmodule Harness.SettingsStore do
  @moduledoc """
  Single key-value persistence layer for runtime-flippable harness settings.

  With `repo_enabled: true` (the harness self-host and any Oban deployment) the
  `harness_settings` Postgres table is the **single source of truth**: every
  operator-flippable setting — landing policy/target, cron toggles + schedule,
  agent enablement, reviewer pins, operator config overrides — reads from and
  writes to that one table. A process-local ETS cache sits in front of the
  backend as write-through memory (the same shape `Harness.Config` uses for its
  own keys): `put/2` updates the backend and the cache before returning, so the
  next `fetch/1` sees the write. A BEAM restart empties the cache; the next
  read refills from Postgres.

  Library consumers that mount harness with `repo_enabled: false` get an
  ephemeral no-op store (`fetch` ⇒ `:not_found`, `put` ⇒ `:ok`): settings cannot
  be bootstrapped from the database that isn't there, so they fall back to the
  in-code defaults (the dashboard surfaces this to the operator). The cache is
  not consulted on that path.
  """

  alias Harness.Store.EtsHeir

  @type key :: atom() | String.t()
  @type store :: {module(), keyword()} | module() | false

  @callback fetch(String.t(), keyword()) :: {:ok, term()} | :not_found | {:error, term()}
  @callback put(String.t(), term(), keyword()) :: :ok | {:error, term()}

  @cache_table __MODULE__.Cache
  @heir_name __MODULE__.Heir

  @doc "Fetches a persisted setting value by key."
  @spec fetch(key()) :: {:ok, term()} | :not_found | {:error, term()}
  def fetch(key), do: cached_fetch(configured(), normalize_key(key))

  @doc "Persists a setting value by key."
  @spec put(key(), term()) :: :ok | {:error, term()}
  def put(key, value) do
    key = normalize_key(key)
    store = configured()

    case dispatch_put(store, key, value) do
      :ok ->
        write_through(store, key, value)
        :ok

      error ->
        error
    end
  end

  @doc """
  Fetches a persisted **map** setting, returning `%{}` when the key is missing or
  the stored value is not a map.

  Convenience for the settings records that persist a single map keyed by one
  store key (agent enablement, cron toggles): the caller writes the map back with
  one key replaced, so a missing row reads as the empty record.
  """
  @spec fetch_map(key()) :: map()
  def fetch_map(key) do
    case fetch(key) do
      {:ok, map} when is_map(map) -> map
      _missing_or_invalid -> %{}
    end
  end

  @doc "Returns the configured backend: Postgres when `:repo_enabled`, the ephemeral no-op store otherwise."
  @spec configured() :: store()
  def configured do
    case Application.get_env(:harness, :settings_store) do
      nil ->
        if Application.get_env(:harness, :repo_enabled, true) do
          {Harness.SettingsStore.Postgres, []}
        else
          false
        end

      store ->
        store
    end
  end

  @doc false
  @spec reset_cache() :: :ok
  def reset_cache do
    case :ets.whereis(@cache_table) do
      :undefined ->
        :ok

      _table ->
        true = :ets.delete_all_objects(@cache_table)
        :ok
    end
  end

  @spec cached_fetch(store(), String.t()) :: {:ok, term()} | :not_found | {:error, term()}
  defp cached_fetch(false, _key), do: :not_found

  defp cached_fetch(store, key) do
    case cache_lookup(store, key) do
      {:ok, result} -> result
      :miss -> remember(store, key, dispatch_fetch(store, key))
    end
  end

  @spec remember(store(), String.t(), {:ok, term()} | :not_found | {:error, term()}) ::
          {:ok, term()} | :not_found | {:error, term()}
  defp remember(_store, _key, {:error, _} = error), do: error

  defp remember(store, key, result) do
    if cache_insert_new(store, key, result) do
      result
    else
      case cache_lookup(store, key) do
        {:ok, cached} ->
          cached

        :miss ->
          cache_insert(store, key, result)
          result
      end
    end
  end

  @spec write_through(store(), String.t(), term()) :: :ok
  defp write_through(false, _key, _value), do: :ok
  defp write_through(store, key, value), do: cache_insert(store, key, {:ok, value})

  @spec dispatch_fetch(store(), String.t()) :: {:ok, term()} | :not_found | {:error, term()}
  defp dispatch_fetch(store, key) do
    {module, backend_opts} = normalize_store(store)
    module.fetch(key, backend_opts)
  end

  @spec dispatch_put(store(), String.t(), term()) :: :ok | {:error, term()}
  defp dispatch_put(false, _key, _value), do: :ok

  defp dispatch_put(store, key, value) do
    {module, backend_opts} = normalize_store(store)
    module.put(key, value, backend_opts)
  end

  @spec cache_lookup(store(), String.t()) :: {:ok, {:ok, term()} | :not_found} | :miss
  defp cache_lookup(store, key) do
    case :ets.lookup(cache_table(), {cache_fingerprint(store), key}) do
      [{_slot, result}] -> {:ok, result}
      [] -> :miss
    end
  end

  @spec cache_insert(store(), String.t(), {:ok, term()} | :not_found) :: :ok
  defp cache_insert(store, key, result) do
    true = :ets.insert(cache_table(), {{cache_fingerprint(store), key}, result})
    :ok
  end

  @spec cache_insert_new(store(), String.t(), {:ok, term()} | :not_found) :: boolean()
  defp cache_insert_new(store, key, result) do
    :ets.insert_new(cache_table(), {{cache_fingerprint(store), key}, result})
  end

  @spec cache_table() :: :ets.tid() | atom()
  defp cache_table do
    case :ets.whereis(@cache_table) do
      :undefined -> create_cache_table()
      table -> table
    end
  end

  @spec create_cache_table() :: :ets.tid() | atom()
  defp create_cache_table do
    :ets.new(@cache_table, [
      :named_table,
      :public,
      :set,
      {:heir, EtsHeir.pid(@heir_name), :settings_cache},
      read_concurrency: true,
      write_concurrency: true
    ])
  rescue
    ArgumentError -> @cache_table
  end

  @spec cache_fingerprint(store()) :: term()
  defp cache_fingerprint({module, opts}) when is_atom(module) and is_list(opts) do
    {module, Keyword.take(opts, [:scope, :repo])}
  end

  defp cache_fingerprint(module) when is_atom(module), do: {module, []}

  @spec normalize_store(store()) :: {module(), keyword()}
  defp normalize_store({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}
  defp normalize_store(module) when is_atom(module), do: {module, []}

  @spec normalize_key(key()) :: String.t()
  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
end
