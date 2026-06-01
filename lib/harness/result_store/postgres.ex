defmodule Harness.ResultStore.Postgres do
  @moduledoc """
  Postgres-backed `Harness.ResultStore` implementation (Task 137).

  Uses the existing `Harness.Repo` (Oban dependency). All operations are
  best-effort: return `{:error, _}` on any failure (connection, constraint,
  serialization) and never raise, per the behaviour contract.
  """

  @behaviour Harness.ResultStore

  import Ecto.Query

  alias Harness.Batch.Result, as: BatchResult
  alias Harness.Repo
  alias Harness.ResultStore.Schema.BatchResult, as: BatchResultSchema
  alias Harness.ResultStore.Schema.RunRecord, as: RunRecordSchema
  alias Harness.Run.LogRecord

  require Logger

  @impl Harness.ResultStore
  @spec record_run(LogRecord.t(), keyword()) :: :ok | {:error, term()}
  def record_run(%LogRecord{} = record, opts) when is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)
    attrs = log_record_to_attrs(record)

    schema = %RunRecordSchema{run_id: record.run_id}
    changeset = RunRecordSchema.changeset(schema, attrs)

    try do
      case repo.insert(changeset, on_conflict: :replace_all, conflict_target: :run_id) do
        {:ok, _} -> :ok
        {:error, cs} -> {:error, {:changeset, cs.errors}}
      end
    rescue
      e -> {:error, e}
    end
  end

  @impl Harness.ResultStore
  @spec save_batch(BatchResult.t(), keyword()) :: :ok | {:error, term()}
  def save_batch(%BatchResult{} = result, opts) when is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)

    payload = :erlang.term_to_binary(result)

    attrs = %{
      batch_id: result.batch_id,
      total: result.total,
      max_concurrency: result.max_concurrency,
      payload: payload
    }

    schema = %BatchResultSchema{batch_id: result.batch_id}
    changeset = BatchResultSchema.changeset(schema, attrs)

    try do
      case repo.insert(changeset, on_conflict: :replace_all, conflict_target: :batch_id) do
        {:ok, _} -> :ok
        {:error, cs} -> {:error, {:changeset, cs.errors}}
      end
    rescue
      e -> {:error, e}
    end
  end

  @impl Harness.ResultStore
  @spec load_batch(String.t(), keyword()) :: {:ok, BatchResult.t()} | {:error, term()}
  def load_batch(batch_id, opts) when is_binary(batch_id) and is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)

    try do
      case repo.get(BatchResultSchema, batch_id) do
        nil ->
          {:error, :not_found}

        %BatchResultSchema{payload: payload} when is_binary(payload) ->
          case safe_binary_to_term(payload) do
            {:ok, %BatchResult{} = br} -> {:ok, br}
            {:ok, _other} -> {:error, {:invalid_term_payload, batch_id}}
            {:error, r} -> {:error, r}
          end

        _ ->
          {:error, {:invalid_row, batch_id}}
      end
    rescue
      e -> {:error, e}
    end
  end

  @impl Harness.ResultStore
  @spec list_run_records(Harness.ResultStore.filters(), keyword()) :: {:ok, [LogRecord.t()]} | {:error, term()}
  def list_run_records(filters, opts) when is_list(filters) and is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)

    try do
      query =
        from r in RunRecordSchema,
          order_by: [desc: r.inserted_at]

      query = apply_filters(query, filters)

      rows = repo.all(query)
      {:ok, Enum.map(rows, &row_to_log_record/1)}
    rescue
      e -> {:error, e}
    end
  end

  # --- filter translation (documented keys only; others ignored for forward compat) ---

  @spec apply_filters(Ecto.Query.t(), Harness.ResultStore.filters()) :: Ecto.Query.t()
  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn {key, value}, q ->
      case key do
        :run_id -> where(q, [r], r.run_id == ^value)
        :batch_id -> where(q, [r], r.batch_id == ^value)
        :agent -> where(q, [r], r.agent == ^atom_or_string(value))
        :adapter -> where(q, [r], r.adapter == ^module_or_string(value))
        :verdict -> where(q, [r], r.verdict == ^atom_or_string(value))
        :project_name -> where(q, [r], r.project_name == ^value)
        _ -> q
      end
    end)
  end

  @spec atom_or_string(atom() | String.t() | nil) :: String.t() | nil
  defp atom_or_string(nil), do: nil
  defp atom_or_string(a) when is_atom(a), do: Atom.to_string(a)
  defp atom_or_string(s) when is_binary(s), do: s

  @spec module_or_string(module() | String.t() | nil) :: String.t() | nil
  defp module_or_string(nil), do: nil
  defp module_or_string(m) when is_atom(m), do: Atom.to_string(m)
  defp module_or_string(s) when is_binary(s), do: s

  # --- LogRecord <-> attrs / row ---

  @spec log_record_to_attrs(LogRecord.t()) :: map()
  defp log_record_to_attrs(%LogRecord{} = r) do
    %{
      run_id: r.run_id,
      batch_id: r.batch_id,
      task_id: r.task_id,
      project_name: r.project_name,
      agent: atom_or_string(r.agent),
      model: r.model,
      adapter: module_or_string(r.adapter),
      state: atom_or_string(r.state),
      verdict: atom_or_string(r.verdict),
      agent_outcome_kind: atom_or_string(r.agent_outcome_kind),
      duration_ms: r.duration_ms,
      repair_attempts: r.repair_attempts,
      first_attempt_failed_check_count: r.first_attempt_failed_check_count,
      agent_diff_size: r.agent_diff_size,
      agent_exit_status: r.agent_exit_status,
      reason: encode_term(r.reason),
      token_usage: encode_term(r.token_usage),
      composed_inputs: encode_term(r.composed_inputs),
      failure_cause: encode_term(r.failure_cause),
      check_output: encode_term(r.check_output),
      domains: encode_term(r.domains),
      agent_output: r.agent_output
    }
  end

  @spec row_to_log_record(RunRecordSchema.t()) :: LogRecord.t()
  defp row_to_log_record(%RunRecordSchema{} = row) do
    %LogRecord{
      batch_id: row.batch_id,
      run_id: row.run_id,
      task_id: row.task_id,
      project_name: row.project_name,
      agent: string_to_atom(row.agent),
      model: row.model,
      adapter: string_to_module(row.adapter),
      state: string_to_atom(row.state),
      reason: decode_term(row.reason),
      verdict: string_to_atom(row.verdict),
      duration_ms: default(row.duration_ms, 0),
      repair_attempts: default(row.repair_attempts, 0),
      first_attempt_failed_check_count: default(row.first_attempt_failed_check_count, 0),
      agent_diff_size: row.agent_diff_size,
      token_usage: default(decode_term(row.token_usage), %Harness.TokenUsage{}),
      composed_inputs: default(decode_term(row.composed_inputs), []),
      failure_cause: default(decode_term(row.failure_cause), %{reason: nil, failed_checks: []}),
      agent_outcome_kind: string_to_atom(row.agent_outcome_kind),
      agent_exit_status: row.agent_exit_status,
      agent_output: default(row.agent_output, ""),
      check_output: default(decode_term(row.check_output), %{}),
      domains: default(decode_term(row.domains), [])
    }
  end

  @spec default(any(), any()) :: any()
  defp default(nil, default), do: default
  defp default(value, _default), do: value

  # Column values come from our own INSERTs (Atom.to_string in log_record_to_attrs)
  # — never user-supplied. Matches manifest.ex / chat/tools.ex pattern.
  # sobelow_skip ["DOS.StringToAtom"]
  @spec string_to_atom(String.t() | nil) :: atom() | nil
  defp string_to_atom(nil), do: nil
  defp string_to_atom(s) when is_binary(s), do: String.to_atom(s)

  # Column values come from our own INSERTs (Atom.to_string in log_record_to_attrs)
  # — never user-supplied. Matches manifest.ex / chat/tools.ex pattern.
  # sobelow_skip ["DOS.StringToAtom"]
  @spec string_to_module(String.t() | nil) :: module() | nil
  defp string_to_module(nil), do: nil
  defp string_to_module(s) when is_binary(s), do: String.to_atom(s)

  # --- term <-> json-safe (tuple roundtrip for reason, atom keys/values, structs) ---

  @spec encode_term(term()) :: term()
  defp encode_term(nil), do: nil
  defp encode_term(atom) when is_atom(atom), do: %{"$atom" => Atom.to_string(atom)}

  defp encode_term(t) when is_tuple(t) do
    %{"$tuple" => t |> Tuple.to_list() |> Enum.map(&encode_term/1)}
  end

  defp encode_term(%_{} = s), do: encode_term(Map.from_struct(s))

  defp encode_term(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {encode_map_key(k), encode_term(v)} end)
  end

  defp encode_term(list) when is_list(list), do: Enum.map(list, &encode_term/1)
  defp encode_term(other), do: other

  @spec encode_map_key(atom() | String.t() | term()) :: String.t()
  defp encode_map_key(k) when is_atom(k), do: Atom.to_string(k)
  defp encode_map_key(k) when is_binary(k), do: k
  defp encode_map_key(k), do: inspect(k)

  # $atom markers come only from our encode_term/encode_map_key (harness-controlled)
  # — not user-supplied free text. Matches manifest.ex / chat/tools.ex pattern.
  # sobelow_skip ["DOS.StringToAtom"]
  @spec decode_term(term()) :: term()
  defp decode_term(nil), do: nil
  defp decode_term(%{"$atom" => name}) when is_binary(name), do: String.to_atom(name)

  defp decode_term(%{"$tuple" => list}) when is_list(list) do
    list |> Enum.map(&decode_term/1) |> List.to_tuple()
  end

  defp decode_term(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {decode_map_key(k), decode_term(v)} end)
  end

  defp decode_term(list) when is_list(list), do: Enum.map(list, &decode_term/1)
  defp decode_term(other), do: other

  # Map keys come only from our encode_term (harness-controlled jsonb roundtrip)
  # — not user-supplied free text. Matches manifest.ex / chat/tools.ex pattern.
  # sobelow_skip ["DOS.StringToAtom"]
  @spec decode_map_key(String.t() | term()) :: atom() | String.t()
  defp decode_map_key(k) when is_binary(k), do: String.to_atom(k)
  defp decode_map_key(k), do: k

  # --- safe term decode (mirrors File resilience) ---

  # Decodes harness-owned term binary (batch_results.payload written via
  # term_to_binary on %Batch.Result{} we control in save_batch). Not
  # untrusted input. Rescue still catches torn bytes.
  # sobelow_skip ["Misc.BinToTerm"]
  @spec safe_binary_to_term(binary()) :: {:ok, term()} | {:error, term()}
  defp safe_binary_to_term(bin) when is_binary(bin) do
    {:ok, :erlang.binary_to_term(bin)}
  rescue
    ArgumentError -> {:error, :invalid_term}
  end

  # --- test helper: expose sandbox checkout for DataCase consumers ---
  @doc false
  @spec ensure_sandbox() :: :ok
  def ensure_sandbox do
    # No-op marker; real checkout lives in Harness.DataCase
    :ok
  end
end
