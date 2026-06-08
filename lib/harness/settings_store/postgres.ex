defmodule Harness.SettingsStore.Postgres do
  @moduledoc """
  Postgres-backed `Harness.SettingsStore` backend — the single source of truth
  for operator-flippable settings when `:repo_enabled`.

  Values are Erlang term payloads keyed by a short settings namespace
  (`"landing"`, `"cron"`, `"agent"`, `"config"`). A missing row reads as
  `:not_found`.
  """

  @behaviour Harness.SettingsStore

  alias Harness.Repo
  alias Harness.SettingsStore.Schema.Setting

  @impl Harness.SettingsStore
  @spec fetch(String.t(), keyword()) :: {:ok, term()} | :not_found | {:error, term()}
  def fetch(key, backend_opts) when is_binary(key) and is_list(backend_opts) do
    repo = Keyword.get(backend_opts, :repo, Repo)

    case repo.get(Setting, key) do
      nil -> :not_found
      %Setting{payload: payload} -> decode_payload(key, payload)
    end
  rescue
    e -> {:error, e}
  end

  @impl Harness.SettingsStore
  @spec put(String.t(), term(), keyword()) :: :ok | {:error, term()}
  def put(key, value, backend_opts) when is_binary(key) and is_list(backend_opts) do
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

  @spec decode_payload(String.t(), term()) :: {:ok, term()} | {:error, term()}
  defp decode_payload(key, payload) when is_binary(payload) do
    case decode_term(payload) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, {:invalid_settings_payload, key, reason}}
    end
  end

  defp decode_payload(key, _payload), do: {:error, {:missing_settings_payload, key}}

  # Payloads are harness-owned database blobs written by put/3.
  # sobelow_skip ["Misc.BinToTerm"]
  @spec decode_term(binary()) :: {:ok, term()} | {:error, :invalid_term}
  defp decode_term(payload) do
    {:ok, :erlang.binary_to_term(payload)}
  rescue
    ArgumentError -> {:error, :invalid_term}
  end
end
