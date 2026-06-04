defmodule Harness.SettingsStore do
  @moduledoc """
  Shared key-value persistence for runtime-flippable harness settings.

  `repo_enabled: true` stores values in Postgres (`harness_settings`); library
  consumers with `repo_enabled: false` use the file backend. Domain modules keep
  app env as their live cache and use this module only for restart persistence.
  """

  @type key :: atom() | String.t()
  @type store :: module() | {module(), keyword()} | nil | false
  @type legacy_opts :: [
          legacy_config_key: atom(),
          legacy_filename: String.t(),
          default_root: String.t()
        ]

  @callback fetch(String.t(), keyword(), keyword()) :: {:ok, term()} | :not_found | {:error, term()}
  @callback put(String.t(), term(), keyword(), keyword()) :: :ok | {:error, term()}

  @default_root "~/.harness"

  @doc "Fetches a persisted setting value by key."
  @spec fetch(key(), legacy_opts()) :: {:ok, term()} | :not_found | {:error, term()}
  def fetch(key, opts) when is_list(opts) do
    if disabled?(opts), do: :not_found, else: dispatch(configured(), :fetch, [normalize_key(key), opts])
  end

  @doc "Persists a setting value by key."
  @spec put(key(), term(), legacy_opts()) :: :ok | {:error, term()}
  def put(key, value, opts) when is_list(opts) do
    if disabled?(opts), do: :ok, else: dispatch(configured(), :put, [normalize_key(key), value, opts])
  end

  @doc "Returns the configured backend, defaulting by `:repo_enabled`."
  @spec configured() :: store()
  def configured do
    case Application.get_env(:harness, :settings_store) do
      nil ->
        if Application.get_env(:harness, :repo_enabled, true) do
          {Harness.SettingsStore.Postgres, []}
        else
          {Harness.SettingsStore.File, []}
        end

      store ->
        store
    end
  end

  @doc false
  @spec disabled?(keyword()) :: boolean()
  def disabled?(opts) do
    case Keyword.fetch(opts, :legacy_config_key) do
      {:ok, key} -> Application.get_env(:harness, key, root: @default_root) in [false, nil]
      :error -> false
    end
  end

  @doc false
  @spec file_root(keyword(), keyword()) :: String.t()
  def file_root(backend_opts, opts) do
    root =
      case Keyword.get(backend_opts, :root) do
        nil -> legacy_root(opts)
        root -> root
      end

    Path.expand(root)
  end

  @doc false
  @spec legacy_path(keyword()) :: String.t() | nil
  def legacy_path(opts) do
    with {:ok, filename} <- Keyword.fetch(opts, :legacy_filename),
         root when is_binary(root) <- legacy_root(opts) do
      Path.join(Path.expand(root), filename)
    else
      _other -> nil
    end
  end

  @doc false
  @spec legacy_root(keyword()) :: String.t()
  def legacy_root(opts) do
    default = Keyword.get(opts, :default_root, @default_root)

    case Keyword.get(opts, :legacy_config_key) do
      nil ->
        default

      key ->
        case Application.get_env(:harness, key, root: default) do
          list when is_list(list) -> Keyword.get(list, :root, default)
          _disabled -> default
        end
    end
  end

  @spec normalize_key(key()) :: String.t()
  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key

  @spec dispatch(store(), atom(), [term()]) :: term()
  defp dispatch(false, :fetch, [_key, _opts]), do: :not_found
  defp dispatch(nil, :fetch, [_key, _opts]), do: :not_found
  defp dispatch(false, :put, [_key, _value, _opts]), do: :ok
  defp dispatch(nil, :put, [_key, _value, _opts]), do: :ok

  defp dispatch({module, backend_opts}, function, args) when is_atom(module) and is_list(backend_opts) do
    apply(module, function, args ++ [backend_opts])
  end

  defp dispatch(module, function, args) when is_atom(module) do
    apply(module, function, args ++ [[]])
  end
end
