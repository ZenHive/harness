defmodule Harness.SettingsStore.Postgres do
  @moduledoc """
  Postgres-backed `Harness.SettingsStore` backend.

  Values are Erlang term payloads keyed by a short settings namespace. Missing
  rows are lazily seeded from the legacy file for that namespace, preserving
  operator toggles on the first boot after upgrading.
  """

  @behaviour Harness.SettingsStore

  alias Harness.Repo
  alias Harness.SettingsStore
  alias Harness.SettingsStore.Schema.Setting
  alias Harness.TermCodec

  @impl SettingsStore
  @spec fetch(String.t(), keyword(), keyword()) :: {:ok, term()} | :not_found | {:error, term()}
  def fetch(key, opts, backend_opts) when is_binary(key) and is_list(opts) and is_list(backend_opts) do
    repo = Keyword.get(backend_opts, :repo, Repo)

    case repo.get(Setting, key) do
      nil -> import_legacy(key, opts, backend_opts)
      %Setting{payload: payload} -> decode_payload(key, payload)
    end
  rescue
    e -> {:error, e}
  end

  @impl SettingsStore
  @spec put(String.t(), term(), keyword(), keyword()) :: :ok | {:error, term()}
  def put(key, value, _opts, backend_opts) when is_binary(key) and is_list(backend_opts) do
    repo = Keyword.get(backend_opts, :repo, Repo)
    attrs = %{key: key, payload: :erlang.term_to_binary(value)}
    changeset = Setting.changeset(%Setting{key: key}, attrs)

    case repo.insert(changeset, on_conflict: {:replace, [:payload, :updated_at]}, conflict_target: :key) do
      {:ok, _row} -> :ok
      {:error, cs} -> {:error, {:changeset, cs.errors}}
    end
  rescue
    e -> {:error, e}
  end

  @spec import_legacy(String.t(), keyword(), keyword()) :: {:ok, term()} | :not_found | {:error, term()}
  defp import_legacy(key, opts, backend_opts) do
    case SettingsStore.legacy_path(opts) do
      nil ->
        :not_found

      legacy_path ->
        case TermCodec.read_file(legacy_path) do
          {:ok, value} ->
            case put(key, value, opts, backend_opts) do
              :ok -> {:ok, value}
              {:error, _reason} = error -> error
            end

          {:error, :enoent} ->
            :not_found

          {:error, _reason} = error ->
            error
        end
    end
  end

  @spec decode_payload(String.t(), term()) :: {:ok, term()} | {:error, term()}
  defp decode_payload(key, payload) when is_binary(payload) do
    case TermCodec.safe_binary_to_term(payload) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, {:invalid_settings_payload, key, reason}}
    end
  end

  defp decode_payload(key, _payload), do: {:error, {:missing_settings_payload, key}}
end
