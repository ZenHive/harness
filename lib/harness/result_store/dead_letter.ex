defmodule Harness.ResultStore.DeadLetter do
  @moduledoc """
  Durable spill for failed settle-time `run_records` inserts (Task 370).

  Schema/DB drift (e.g. a hot-reloaded schema against an unmigrated DB → Postgrex
  `undefined_column`) must not silently drop an approved run's record. The full
  `%Harness.Run.LogRecord{}` is written as a safe ETF file under a configurable
  root (default `~/.harness/run_record_dead_letter/`) and replayed once the insert
  path works again.

  Mechanical only — no judgment about the migration itself. Operator runs
  `mix ecto.migrate`; harness spills, names pending migrations when detectable,
  and replays.
  """

  alias Harness.Run.LogRecord

  require Logger

  @default_root "~/.harness/run_record_dead_letter"
  @entry_version 1

  @typedoc "One spilled run-record payload on disk."
  @type entry :: %{
          v: pos_integer(),
          run_id: String.t(),
          record: LogRecord.t(),
          reason: term(),
          failed_at: DateTime.t(),
          pending_migrations: [{integer(), String.t()}],
          path: String.t()
        }

  @doc """
  Absolute root directory for spilled run records.

  Override with `config :harness, :result_store_dead_letter, root: path`.
  """
  @spec root() :: String.t()
  def root do
    case Application.get_env(:harness, :result_store_dead_letter, []) do
      opts when is_list(opts) ->
        opts
        |> Keyword.get(:root, @default_root)
        |> expand_root()

      path when is_binary(path) and path != "" ->
        expand_root(path)

      _other ->
        expand_root(@default_root)
    end
  end

  @doc "Absolute path of the spill file for `run_id`."
  @spec path_for(String.t()) :: String.t()
  def path_for(run_id) when is_binary(run_id) do
    Path.join(root(), sanitize_run_id(run_id) <> ".etf")
  end

  @doc """
  Writes `record` to the dead-letter root. Overwrites any prior spill for the
  same `run_id` (last settle attempt wins). Returns `{:ok, entry}` or
  `{:error, reason}` on filesystem failure.
  """
  # sobelow_skip ["Traversal.FileModule"] — root is operator config; path_for/1 sanitizes the run id.
  @spec spill(LogRecord.t(), term(), keyword()) :: {:ok, entry()} | {:error, term()}
  def spill(%LogRecord{run_id: run_id} = record, reason, opts \\ []) when is_binary(run_id) and is_list(opts) do
    with_run_lock(run_id, fn ->
      pending = Keyword.get(opts, :pending_migrations, [])
      path = path_for(run_id)

      entry = %{
        v: @entry_version,
        run_id: run_id,
        record: record,
        reason: encode_reason(reason),
        failed_at: DateTime.truncate(DateTime.utc_now(), :second),
        pending_migrations: normalize_pending(pending),
        path: path
      }

      with :ok <- File.mkdir_p(root()),
           :ok <- atomic_write(path, :erlang.term_to_binary(entry)) do
        {:ok, entry}
      end
    end)
  end

  @doc false
  @spec with_run_lock(String.t(), (-> term())) :: term()
  def with_run_lock(run_id, fun) when is_binary(run_id) and is_function(fun, 0) do
    :global.trans({{__MODULE__, run_id}, self()}, fun)
  end

  @doc false
  @spec patch_landed_sha_locked(String.t(), String.t()) :: :ok | {:error, term()}
  def patch_landed_sha_locked(run_id, sha) when is_binary(run_id) and is_binary(sha) do
    case load(run_id) do
      {:ok, %{record: %LogRecord{} = record} = entry} ->
        atomic_write(entry.path, :erlang.term_to_binary(%{entry | record: %{record | landed_sha: sha}}))

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Patches a spilled record's `landed_sha` when the lander's writeback finds no DB
  row (insert was spilled). No-op when no spill exists. Returns `:ok` or
  `{:error, reason}`.
  """
  @spec patch_landed_sha(String.t(), String.t()) :: :ok | {:error, term()}
  def patch_landed_sha(run_id, sha) when is_binary(run_id) and is_binary(sha) do
    with_run_lock(run_id, fn -> patch_landed_sha_locked(run_id, sha) end)
  end

  @doc "Loads one spill by `run_id`."
  # sobelow_skip ["Traversal.FileModule"] — path_for/1 confines a sanitized run id to the configured root.
  @spec load(String.t()) :: {:ok, entry()} | {:error, :not_found | term()}
  def load(run_id) when is_binary(run_id) do
    path = path_for(run_id)

    case File.read(path) do
      {:ok, bin} -> decode_entry(bin, path)
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "True when a spill file exists for `run_id`."
  @spec exists?(String.t()) :: boolean()
  def exists?(run_id) when is_binary(run_id) do
    File.exists?(path_for(run_id))
  end

  @doc "Deletes the spill for `run_id` after a successful replay. Idempotent."
  # sobelow_skip ["Traversal.FileModule"] — path_for/1 confines a sanitized run id to the configured root.
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(run_id) when is_binary(run_id) do
    case File.rm(path_for(run_id)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Lists every readable spill entry under the dead-letter root (unsorted)."
  @spec list() :: [entry()]
  def list do
    dir = root()

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".etf"))
        |> Enum.flat_map(&load_list_entry(Path.join(dir, &1)))

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning("harness dead-letter: failed to list #{dir}: #{inspect(reason)}")
        []
    end
  end

  # sobelow_skip ["Traversal.FileModule"] — path is returned by File.ls/1 under the operator-configured root.
  @spec load_list_entry(String.t()) :: [entry()]
  defp load_list_entry(path) do
    case File.read(path) do
      {:ok, bin} -> decode_list_entry(bin, path)
      {:error, _} -> []
    end
  end

  @spec decode_list_entry(binary(), String.t()) :: [entry()]
  defp decode_list_entry(bin, path) do
    case decode_entry(bin, path) do
      {:ok, entry} ->
        [entry]

      {:error, reason} ->
        Logger.warning("harness dead-letter: skipping corrupt spill #{path}: #{inspect(reason)}")
        []
    end
  end

  @spec expand_root(String.t()) :: String.t()
  defp expand_root(path), do: Path.expand(path)

  # sobelow_skip ["Traversal.FileModule"] — caller paths come from path_for/1 or decoded entries rooted by load/1.
  @spec atomic_write(String.t(), binary()) :: :ok | {:error, term()}
  defp atomic_write(path, binary) do
    temp_path = path <> ".#{System.unique_integer([:positive, :monotonic])}.tmp"

    case File.write(temp_path, binary, [:binary, :sync]) do
      :ok -> rename_temp(temp_path, path)
      {:error, reason} -> {:error, reason}
    end
  end

  # sobelow_skip ["Traversal.FileModule"] — both paths are generated by atomic_write/2 under the configured root.
  @spec rename_temp(String.t(), String.t()) :: :ok | {:error, term()}
  defp rename_temp(temp_path, path) do
    case File.rename(temp_path, path) do
      :ok ->
        :ok

      {:error, reason} ->
        _ = File.rm(temp_path)
        {:error, reason}
    end
  end

  # run_ids are harness-minted (`run-<ms>-<hex>`); strip path separators / `..`
  # so a malicious/corrupt id cannot escape the dead-letter root.
  @spec sanitize_run_id(String.t()) :: String.t()
  defp sanitize_run_id(run_id) do
    run_id
    |> String.replace(~r/[^A-Za-z0-9_-]/, "_")
    |> case do
      "" -> "unknown"
      safe -> safe
    end
  end

  @spec normalize_pending(term()) :: [{integer(), String.t()}]
  defp normalize_pending(list) when is_list(list) do
    Enum.flat_map(list, fn
      {version, name} when is_integer(version) and is_binary(name) -> [{version, name}]
      {_status, version, name} when is_integer(version) and is_binary(name) -> [{version, name}]
      _other -> []
    end)
  end

  defp normalize_pending(_other), do: []

  @spec encode_reason(term()) :: term()
  defp encode_reason(%Postgrex.Error{postgres: postgres} = error) when is_map(postgres) do
    %{
      "class" => "postgrex",
      "message" => Exception.message(error),
      "code" => Map.get(postgres, :code),
      "pg_code" => Map.get(postgres, :pg_code)
    }
  end

  defp encode_reason(%{__exception__: true} = error) do
    %{
      "class" => "exception",
      "type" => error.__struct__ |> Module.split() |> List.last(),
      "message" => Exception.message(error)
    }
  end

  defp encode_reason(reason) when is_atom(reason) or is_binary(reason) or is_number(reason), do: reason
  defp encode_reason(reason), do: inspect(reason)

  # Payloads are harness-owned local spill files written by this module.
  # sobelow_skip ["Misc.BinToTerm"]
  @spec decode_entry(binary(), String.t()) :: {:ok, entry()} | {:error, term()}
  defp decode_entry(bin, path) when is_binary(bin) do
    case :erlang.binary_to_term(bin, [:safe]) do
      %{v: @entry_version, run_id: run_id, record: %LogRecord{} = record} = entry
      when is_binary(run_id) ->
        {:ok,
         %{
           v: @entry_version,
           run_id: run_id,
           record: record,
           reason: Map.get(entry, :reason),
           failed_at: Map.get(entry, :failed_at),
           pending_migrations: normalize_pending(Map.get(entry, :pending_migrations, [])),
           path: path
         }}

      _other ->
        {:error, :invalid_entry}
    end
  rescue
    ArgumentError -> {:error, :invalid_term}
  end
end
