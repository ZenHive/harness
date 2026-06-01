defmodule Harness.ResultStore.Postgres do
  @moduledoc """
  Postgres-backed `Harness.ResultStore` implementation (Task 137).

  Uses the existing `Harness.Repo` (Oban dependency). All operations are
  best-effort: return `{:error, _}` on any failure (connection, constraint,
  serialization) and never raise, per the behaviour contract.
  """

  @behaviour Harness.ResultStore

  import Ecto.Query

  alias Harness.AgentKPI
  alias Harness.Batch.Result, as: BatchResult
  alias Harness.CapabilityScore
  alias Harness.Repo
  alias Harness.ResultStore.Schema.BatchResult, as: BatchResultSchema
  alias Harness.ResultStore.Schema.CapabilityScore, as: CapabilityScoreSchema
  alias Harness.ResultStore.Schema.RunRecord, as: RunRecordSchema
  alias Harness.Run.LogRecord
  alias Harness.TokenUsage

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
      {limit, filters} = pop_limit(filters)
      point_lookup? = Keyword.has_key?(filters, :run_id)

      query =
        from r in RunRecordSchema,
          order_by: [desc: r.inserted_at]

      query = apply_filters(query, filters)
      query = if point_lookup?, do: query, else: select_without_agent_output(query)
      query = if limit, do: limit(query, ^limit), else: query

      rows = repo.all(query)
      {:ok, Enum.map(rows, &row_to_log_record/1)}
    rescue
      e -> {:error, e}
    end
  end

  @impl Harness.ResultStore
  @spec aggregate_by_agent(keyword(), keyword()) :: {:ok, AgentKPI.t()} | {:error, term()}
  def aggregate_by_agent(_query_opts, opts) when is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)

    try do
      rows = repo.all(aggregate_by_agent_query())
      {:ok, aggregate_rows_to_ledger(rows)}
    rescue
      e -> {:error, e}
    end
  end

  @spec aggregate_by_agent_query() :: Ecto.Query.t()
  defp aggregate_by_agent_query do
    from r in RunRecordSchema,
      group_by: r.agent,
      select: %{
        agent: r.agent,
        run_count: count(r.run_id),
        pass_count: r.run_id |> count() |> filter(r.verdict == "pass"),
        first_attempt_pass_count: r.run_id |> count() |> filter(r.verdict == "pass" and r.repair_attempts == 0),
        durations: fragment("array_agg(? ORDER BY ?)", r.duration_ms, r.duration_ms),
        repair_attempts_mean: avg(r.repair_attempts),
        input_mean:
          avg(
            fragment(
              "coalesce((?->>'input')::float, 0)",
              r.token_usage
            )
          ),
        output_mean:
          avg(
            fragment(
              "coalesce((?->>'output')::float, 0)",
              r.token_usage
            )
          ),
        total_mean:
          avg(
            fragment(
              "coalesce((?->>'total')::float, 0)",
              r.token_usage
            )
          ),
        pass_count_for_cost: r.run_id |> count() |> filter(r.verdict == "pass"),
        cost_to_green_mean:
          "coalesce((?->>'total')::float, 0)"
          |> fragment(r.token_usage)
          |> avg()
          |> filter(r.verdict == "pass")
      }
  end

  @spec aggregate_rows_to_ledger([map()]) :: AgentKPI.t()
  defp aggregate_rows_to_ledger(rows) do
    Map.new(rows, fn row ->
      run_count = row.run_count
      pass_count = row.pass_count || 0

      cost_to_green =
        if row.pass_count_for_cost > 0, do: float_or_nil(row.cost_to_green_mean)

      kpi = %{
        run_count: run_count,
        success_rate: pass_count / run_count,
        first_attempt_pass_rate: (row.first_attempt_pass_count || 0) / run_count,
        duration_ms: AgentKPI.duration_summary(row.durations || []),
        tokens: %{
          input: float_or_zero(row.input_mean),
          output: float_or_zero(row.output_mean),
          total: float_or_zero(row.total_mean)
        },
        repair_attempts: float_or_zero(row.repair_attempts_mean),
        cost_to_green: cost_to_green
      }

      {string_to_atom(row.agent), kpi}
    end)
  end

  @spec float_or_zero(term()) :: float()
  defp float_or_zero(nil), do: 0.0
  defp float_or_zero(n) when is_number(n), do: n / 1
  defp float_or_zero(value), do: sql_avg_to_float(value) || 0.0

  @spec float_or_nil(term()) :: float() | nil
  defp float_or_nil(nil), do: nil
  defp float_or_nil(n) when is_number(n), do: n / 1
  defp float_or_nil(value), do: sql_avg_to_float(value)

  # Postgres `avg/1` returns `%Decimal{sign, coef, exp}`; avoid `Decimal.to_float/1`
  # so Dialyzer does not require the Decimal app on the PLT.
  @spec sql_avg_to_float(term()) :: float() | nil
  defp sql_avg_to_float(%{sign: sign, coef: coef, exp: exp})
       when sign in [-1, 1] and is_integer(coef) and is_integer(exp) do
    sign * coef * :math.pow(10, exp)
  end

  defp sql_avg_to_float(_), do: nil

  @spec select_without_agent_output(Ecto.Query.t()) :: Ecto.Query.t()
  defp select_without_agent_output(query) do
    from r in query,
      select: %RunRecordSchema{
        run_id: r.run_id,
        batch_id: r.batch_id,
        task_id: r.task_id,
        project_name: r.project_name,
        agent: r.agent,
        model: r.model,
        adapter: r.adapter,
        state: r.state,
        verdict: r.verdict,
        agent_outcome_kind: r.agent_outcome_kind,
        duration_ms: r.duration_ms,
        repair_attempts: r.repair_attempts,
        first_attempt_failed_check_count: r.first_attempt_failed_check_count,
        agent_diff_size: r.agent_diff_size,
        agent_exit_status: r.agent_exit_status,
        reason: r.reason,
        token_usage: r.token_usage,
        composed_inputs: r.composed_inputs,
        failure_cause: r.failure_cause,
        check_output: r.check_output,
        domains: r.domains,
        agent_output: type(^nil, :binary),
        inserted_at: r.inserted_at,
        updated_at: r.updated_at
      }
  end

  @spec pop_limit(Harness.ResultStore.filters()) :: {pos_integer() | nil, Harness.ResultStore.filters()}
  defp pop_limit(filters) do
    case Keyword.pop(filters, :limit) do
      {nil, filters} -> {nil, filters}
      {limit, filters} when is_integer(limit) and limit > 0 -> {limit, filters}
      {_bad, filters} -> {nil, filters}
    end
  end

  @impl Harness.ResultStore
  @spec save_capability_score(CapabilityScore.t(), keyword()) :: :ok | {:error, term()}
  def save_capability_score(%CapabilityScore{} = score, opts) when is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)

    attrs = %{
      agent: atom_or_string(score.agent),
      domain: atom_or_string(score.domain),
      corpus_version: score.corpus_version,
      scored_at: score.scored_at,
      composite_score: score.composite_score,
      payload: :erlang.term_to_binary(score)
    }

    schema = %CapabilityScoreSchema{
      agent: attrs.agent,
      domain: attrs.domain,
      corpus_version: attrs.corpus_version
    }

    changeset = CapabilityScoreSchema.changeset(schema, attrs)

    try do
      case repo.insert(
             changeset,
             on_conflict: :replace_all,
             conflict_target: [:agent, :domain, :corpus_version]
           ) do
        {:ok, _} -> :ok
        {:error, cs} -> {:error, {:changeset, cs.errors}}
      end
    rescue
      e -> {:error, e}
    end
  end

  @impl Harness.ResultStore
  @spec get_capability_score(atom(), atom(), String.t(), keyword()) ::
          {:ok, CapabilityScore.t()} | :no_data | {:error, term()}
  def get_capability_score(agent, domain, corpus_version, opts)
      when is_atom(agent) and is_atom(domain) and is_binary(corpus_version) and is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)

    try do
      repo
      |> fetch_capability_score_row(agent, domain, corpus_version)
      |> decode_capability_score_row(agent, domain, corpus_version)
    rescue
      e -> {:error, e}
    end
  end

  @spec fetch_capability_score_row(module(), atom(), atom(), String.t()) :: CapabilityScoreSchema.t() | nil
  defp fetch_capability_score_row(repo, agent, domain, corpus_version) do
    repo.get_by(CapabilityScoreSchema,
      agent: atom_or_string(agent),
      domain: atom_or_string(domain),
      corpus_version: corpus_version
    )
  end

  @spec decode_capability_score_row(CapabilityScoreSchema.t() | nil, atom(), atom(), String.t()) ::
          {:ok, CapabilityScore.t()} | :no_data | {:error, term()}
  defp decode_capability_score_row(nil, _agent, _domain, _corpus_version), do: :no_data

  defp decode_capability_score_row(%CapabilityScoreSchema{payload: payload}, agent, domain, corpus_version)
       when is_binary(payload) do
    case safe_binary_to_term(payload) do
      {:ok, %CapabilityScore{} = score} -> {:ok, score}
      {:ok, _other} -> {:error, {:invalid_capability_score, agent, domain, corpus_version}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_capability_score_row(_row, agent, domain, corpus_version) do
    {:error, {:invalid_capability_score_row, agent, domain, corpus_version}}
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
      reason: encode_jsonb(r.reason),
      token_usage: encode_jsonb(r.token_usage),
      composed_inputs: encode_jsonb(r.composed_inputs),
      failure_cause: encode_jsonb(r.failure_cause),
      check_output: encode_jsonb(r.check_output),
      domains: encode_jsonb(r.domains),
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
      reason: decode_jsonb(row.reason),
      verdict: string_to_atom(row.verdict),
      duration_ms: default(row.duration_ms, 0),
      repair_attempts: default(row.repair_attempts, 0),
      first_attempt_failed_check_count: default(row.first_attempt_failed_check_count, 0),
      agent_diff_size: row.agent_diff_size,
      token_usage: decode_token_usage(row.token_usage),
      composed_inputs: default(decode_jsonb(row.composed_inputs), []),
      failure_cause: default(decode_jsonb(row.failure_cause), %{reason: nil, failed_checks: []}),
      agent_outcome_kind: string_to_atom(row.agent_outcome_kind),
      agent_exit_status: row.agent_exit_status,
      agent_output: default(row.agent_output, ""),
      check_output: decode_check_output(row.check_output),
      domains: default(decode_jsonb(row.domains), [])
    }
  end

  @spec default(any(), any()) :: any()
  defp default(nil, default), do: default
  defp default(value, _default), do: value

  # Column values come from our own INSERTs (Atom.to_string in log_record_to_attrs)
  # — never user-supplied. Matches manifest.ex / chat/tools.ex pattern.
  # The String.to_atom clause must directly follow this comment for the skip to attach.
  # sobelow_skip ["DOS.StringToAtom"]
  @spec string_to_atom(String.t() | nil) :: atom() | nil
  defp string_to_atom(s) when is_binary(s), do: String.to_atom(s)
  defp string_to_atom(nil), do: nil

  # Column values come from our own INSERTs (Atom.to_string in log_record_to_attrs)
  # — never user-supplied. Matches manifest.ex / chat/tools.ex pattern.
  # The String.to_atom clause must directly follow this comment for the skip to attach.
  # sobelow_skip ["DOS.StringToAtom"]
  @spec string_to_module(String.t() | nil) :: module() | nil
  defp string_to_module(s) when is_binary(s), do: String.to_atom(s)
  defp string_to_module(nil), do: nil

  # --- term <-> json-safe (tuple roundtrip for reason, atom keys/values, structs) ---

  # jsonb columns are Ecto :map fields; a top-level list (composed_inputs, domains)
  # cannot cast to :map, so wrap it in a "$list" marker map. Non-list values pass through.
  @spec encode_jsonb(term()) :: map() | nil
  defp encode_jsonb(value) do
    case encode_term(value) do
      list when is_list(list) -> %{"$list" => list}
      other -> other
    end
  end

  @spec decode_jsonb(term()) :: term()
  defp decode_jsonb(%{"$list" => list}) when is_list(list), do: decode_term(list)
  defp decode_jsonb(other), do: decode_term(other)

  # token_usage is a %TokenUsage{} struct on LogRecord; restore struct identity on read.
  @spec decode_token_usage(map() | nil) :: TokenUsage.t()
  defp decode_token_usage(nil), do: %TokenUsage{}
  defp decode_token_usage(map) when is_map(map), do: struct(TokenUsage, decode_term(map))

  # check_output's outer keys are check-name strings (LogRecord.check_output type);
  # decode values only — the outer keys must never be atomized.
  @spec decode_check_output(map() | nil) :: LogRecord.check_output()
  defp decode_check_output(nil), do: %{}

  defp decode_check_output(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, decode_term(v)} end)
  end

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
  # — not user-supplied free text. Decoded via the skip-annotated string_to_atom/1.
  @spec decode_term(term()) :: term()
  defp decode_term(%{"$atom" => name}) when is_binary(name), do: string_to_atom(name)
  defp decode_term(nil), do: nil

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
