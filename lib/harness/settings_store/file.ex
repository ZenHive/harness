defmodule Harness.SettingsStore.File do
  @moduledoc """
  File-backed `Harness.SettingsStore` backend.

  Stores all settings keys in one `harness_settings.term` file under the
  configured root, while importing the pre-consolidation per-domain term files
  when a key is first requested and not yet present.
  """

  @behaviour Harness.SettingsStore

  alias Harness.SettingsStore
  alias Harness.TermCodec

  @filename "harness_settings.term"

  @impl SettingsStore
  @spec fetch(String.t(), keyword(), keyword()) :: {:ok, term()} | :not_found | {:error, term()}
  def fetch(key, opts, backend_opts) when is_binary(key) and is_list(opts) and is_list(backend_opts) do
    path = path(backend_opts, opts)

    case TermCodec.read_file(path) do
      {:ok, map} when is_map(map) ->
        case Map.fetch(map, key) do
          {:ok, value} -> {:ok, value}
          :error -> import_legacy(key, opts, backend_opts)
        end

      {:error, :enoent} ->
        import_legacy(key, opts, backend_opts)

      {:error, _reason} = error ->
        error

      {:ok, _other} ->
        {:error, {:invalid_settings_file, path}}
    end
  end

  @impl SettingsStore
  @spec put(String.t(), term(), keyword(), keyword()) :: :ok | {:error, term()}
  def put(key, value, opts, backend_opts) when is_binary(key) and is_list(opts) and is_list(backend_opts) do
    path = path(backend_opts, opts)

    map =
      case TermCodec.read_file(path) do
        {:ok, existing} when is_map(existing) -> existing
        _missing_or_invalid -> %{}
      end

    TermCodec.write_file(path, Map.put(map, key, value))
  end

  @spec import_legacy(String.t(), keyword(), keyword()) :: {:ok, term()} | :not_found | {:error, term()}
  defp import_legacy(key, opts, backend_opts) do
    case SettingsStore.legacy_path(opts) do
      nil -> :not_found
      legacy_path -> import_from_legacy_path(key, legacy_path, opts, backend_opts)
    end
  end

  @spec import_from_legacy_path(String.t(), String.t(), keyword(), keyword()) ::
          {:ok, term()} | :not_found | {:error, term()}
  defp import_from_legacy_path(key, legacy_path, opts, backend_opts) do
    case TermCodec.read_file(legacy_path) do
      {:ok, value} -> persist_import(key, value, opts, backend_opts)
      {:error, :enoent} -> :not_found
      {:error, _reason} = error -> error
    end
  end

  @spec persist_import(String.t(), term(), keyword(), keyword()) :: {:ok, term()} | {:error, term()}
  defp persist_import(key, value, opts, backend_opts) do
    case put(key, value, opts, backend_opts) do
      :ok -> {:ok, value}
      {:error, _reason} = error -> error
    end
  end

  @spec path(keyword(), keyword()) :: String.t()
  defp path(backend_opts, opts) do
    backend_opts
    |> SettingsStore.file_root(opts)
    |> Path.join(@filename)
  end
end
