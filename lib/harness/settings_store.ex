defmodule Harness.SettingsStore do
  @moduledoc """
  Single key-value persistence layer for runtime-flippable harness settings.

  With `repo_enabled: true` (the harness self-host and any Oban deployment) the
  `harness_settings` Postgres table is the **single source of truth**: every
  operator-flippable setting — landing policy/target, cron toggles + schedule,
  agent enablement, reviewer pins, operator config overrides — reads from and
  writes to that one table. There is no app-env overlay cache and no exs
  fallback: a value, once set, survives a BEAM restart because the next read
  comes straight back from Postgres.

  Library consumers that mount harness with `repo_enabled: false` get an
  ephemeral no-op store (`fetch` ⇒ `:not_found`, `put` ⇒ `:ok`): settings cannot
  be bootstrapped from the database that isn't there, so they fall back to the
  in-code defaults (the dashboard surfaces this to the operator).

  ## One-time legacy import

  The first read of a key with no Postgres row imports the pre-consolidation
  per-domain term file (`landing_settings.term` / `cron_settings.term` /
  `agent_settings.term` / `config_settings.term`) from `~/.harness` and persists
  it, so an operator's existing flips carry over on the first boot after this
  collapse. After that one import the row exists and Postgres always wins. The
  import is skipped entirely for the ephemeral (`false`) store. `Harness.TermCodec`
  still serves this import (and the other term-backed stores it always has).
  """

  alias Harness.TermCodec

  @type key :: atom() | String.t()
  @type store :: {module(), keyword()} | module() | false

  @callback fetch(String.t(), keyword()) :: {:ok, term()} | :not_found | {:error, term()}
  @callback put(String.t(), term(), keyword()) :: :ok | {:error, term()}

  @default_root "~/.harness"

  # Pre-consolidation per-domain term files imported once on the first read of a
  # missing key, so existing operator flips carry over after the collapse.
  @legacy_filenames %{
    "landing" => "landing_settings.term",
    "cron" => "cron_settings.term",
    "agent" => "agent_settings.term",
    "config" => "config_settings.term"
  }

  @doc "Fetches a persisted setting value by key, importing a legacy term file once if no row exists."
  @spec fetch(key()) :: {:ok, term()} | :not_found | {:error, term()}
  def fetch(key), do: dispatch_fetch(configured(), normalize_key(key))

  @doc "Persists a setting value by key."
  @spec put(key(), term()) :: :ok | {:error, term()}
  def put(key, value), do: dispatch_put(configured(), normalize_key(key), value)

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

  @spec dispatch_fetch(store(), String.t()) :: {:ok, term()} | :not_found | {:error, term()}
  defp dispatch_fetch(false, _key), do: :not_found

  defp dispatch_fetch(store, key) do
    {module, backend_opts} = normalize_store(store)

    case module.fetch(key, backend_opts) do
      :not_found -> import_legacy(key, module, backend_opts)
      other -> other
    end
  end

  @spec dispatch_put(store(), String.t(), term()) :: :ok | {:error, term()}
  defp dispatch_put(false, _key, _value), do: :ok

  defp dispatch_put(store, key, value) do
    {module, backend_opts} = normalize_store(store)
    module.put(key, value, backend_opts)
  end

  @spec normalize_store(store()) :: {module(), keyword()}
  defp normalize_store({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}
  defp normalize_store(module) when is_atom(module), do: {module, []}

  # First read of a missing key: import the legacy per-domain term file (if any)
  # and persist it through the backend, so it exists as a row thereafter.
  @spec import_legacy(String.t(), module(), keyword()) :: {:ok, term()} | :not_found | {:error, term()}
  defp import_legacy(key, module, backend_opts) do
    with {:ok, filename} <- Map.fetch(@legacy_filenames, key),
         {:ok, value} <- TermCodec.read_file(legacy_path(backend_opts, filename)),
         :ok <- module.put(key, value, backend_opts) do
      {:ok, value}
    else
      :error -> :not_found
      {:error, :enoent} -> :not_found
      {:error, _reason} = error -> error
    end
  end

  @spec legacy_path(keyword(), String.t()) :: String.t()
  defp legacy_path(backend_opts, filename) do
    backend_opts
    |> Keyword.get(:legacy_root, @default_root)
    |> Path.expand()
    |> Path.join(filename)
  end

  @spec normalize_key(key()) :: String.t()
  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
end
