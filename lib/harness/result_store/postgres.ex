defmodule Harness.ResultStore.Postgres do
  @moduledoc """
  Postgres-backed `Harness.ResultStore` implementation (Task 137).

  Uses the existing `Harness.Repo` (Oban dependency). All operations are
  best-effort: return `{:error, _}` on any failure (connection, constraint,
  serialization) and never raise, per the behaviour contract.
  """

  @behaviour Harness.ResultStore

  import Ecto.Query

  alias Harness.AgentAdapter.Outcome
  alias Harness.AgentKPI
  alias Harness.Batch.Result, as: BatchResult
  alias Harness.Repo
  alias Harness.ResultStore.Schema.BatchResult, as: BatchResultSchema
  alias Harness.ResultStore.Schema.RunRecord, as: RunRecordSchema
  alias Harness.Run.LogRecord
  alias Harness.TokenUsage

  @impl Harness.ResultStore
  @spec record_run(LogRecord.t(), keyword()) :: :ok | {:error, term()}
  def record_run(%LogRecord{} = record, opts) when is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)

    # Serialization (log_record_to_attrs) stays inside the rescue: a record
    # field the codec can't encode must surface as {:error, _}, never raise
    # into the calling gen_statem (behaviour contract).
    attrs = log_record_to_attrs(record)

    schema = %RunRecordSchema{run_id: record.run_id}
    changeset = RunRecordSchema.changeset(schema, attrs)

    case repo.insert(changeset, on_conflict: conflict_merge_query(), conflict_target: :run_id) do
      {:ok, _} -> :ok
      {:error, cs} -> {:error, {:changeset, cs.errors}}
    end
  rescue
    e -> {:error, e}
  end

  # Same-run_id upsert that never lets a later write's MISSING data clobber a
  # settled attempt's rich evidence (Task 163, the 2026-06-02 data-loss bug):
  # bookkeeping columns always take the incoming row; evidence columns take the
  # incoming value only when it is actually present (COALESCE / NULLIF), and
  # review_iterations keeps the highest count ever recorded. Single atomic
  # round-trip — no read-then-write race.
  @spec conflict_merge_query() :: Ecto.Query.t()
  defp conflict_merge_query do
    from r in RunRecordSchema,
      update: [
        set: [
          # bookkeeping — the latest write wins
          batch_id: fragment("EXCLUDED.batch_id"),
          task_id: fragment("EXCLUDED.task_id"),
          task_fingerprint: fragment("EXCLUDED.task_fingerprint"),
          project_name: fragment("EXCLUDED.project_name"),
          agent: fragment("EXCLUDED.agent"),
          model: fragment("EXCLUDED.model"),
          adapter: fragment("EXCLUDED.adapter"),
          state: fragment("EXCLUDED.state"),
          reason: fragment("EXCLUDED.reason"),
          duration_ms: fragment("EXCLUDED.duration_ms"),
          domains: fragment("EXCLUDED.domains"),
          token_usage: fragment("EXCLUDED.token_usage"),
          composed_inputs: fragment("EXCLUDED.composed_inputs"),
          updated_at: fragment("EXCLUDED.updated_at"),
          # rich evidence — incoming nil/empty never overwrites settled data
          landed_sha: fragment("COALESCE(EXCLUDED.landed_sha, ?)", r.landed_sha),
          verdict: fragment("COALESCE(EXCLUDED.verdict, ?)", r.verdict),
          agent_outcome_kind: fragment("COALESCE(EXCLUDED.agent_outcome_kind, ?)", r.agent_outcome_kind),
          agent_exit_status: fragment("COALESCE(EXCLUDED.agent_exit_status, ?)", r.agent_exit_status),
          agent_diff_size: fragment("COALESCE(EXCLUDED.agent_diff_size, ?)", r.agent_diff_size),
          reviewer_diff_size: fragment("COALESCE(EXCLUDED.reviewer_diff_size, ?)", r.reviewer_diff_size),
          agent_output: fragment("COALESCE(NULLIF(EXCLUDED.agent_output, ''::bytea), ?)", r.agent_output),
          review_iterations:
            fragment(
              "GREATEST(COALESCE(EXCLUDED.review_iterations, 0), COALESCE(?, 0))",
              r.review_iterations
            ),
          reviewer_reprompt_count:
            fragment(
              "GREATEST(COALESCE(EXCLUDED.reviewer_reprompt_count, 0), COALESCE(?, 0))",
              r.reviewer_reprompt_count
            ),
          reviewer_rotation_count:
            fragment(
              "GREATEST(COALESCE(EXCLUDED.reviewer_rotation_count, 0), COALESCE(?, 0))",
              r.reviewer_rotation_count
            ),
          reviewer_adapter: fragment("COALESCE(EXCLUDED.reviewer_adapter, ?)", r.reviewer_adapter),
          reviewer_model: fragment("COALESCE(EXCLUDED.reviewer_model, ?)", r.reviewer_model),
          review_report: fragment("COALESCE(EXCLUDED.review_report, ?)", r.review_report),
          reviewer_outcome_kind: fragment("COALESCE(EXCLUDED.reviewer_outcome_kind, ?)", r.reviewer_outcome_kind),
          reviewer_exit_status: fragment("COALESCE(EXCLUDED.reviewer_exit_status, ?)", r.reviewer_exit_status),
          reviewer_output: fragment("COALESCE(NULLIF(EXCLUDED.reviewer_output, ''::bytea), ?)", r.reviewer_output),
          review_facets: fragment("COALESCE(NULLIF(EXCLUDED.review_facets, '{}'::jsonb), ?)", r.review_facets),
          review_skills: fragment("COALESCE(NULLIF(EXCLUDED.review_skills, '{}'::jsonb), ?)", r.review_skills),
          review_checks: fragment("COALESCE(NULLIF(EXCLUDED.review_checks, '{}'::jsonb), ?)", r.review_checks),
          review_concerns: fragment("COALESCE(NULLIF(EXCLUDED.review_concerns, '{}'::jsonb), ?)", r.review_concerns),
          review_warning?: fragment("(? OR COALESCE(EXCLUDED.review_warning, false))", r.review_warning?),
          review_ratings: fragment("COALESCE(NULLIF(EXCLUDED.review_ratings, '{}'::jsonb), ?)", r.review_ratings),
          recovery_attempts:
            fragment(
              "GREATEST(COALESCE(EXCLUDED.recovery_attempts, 0), COALESCE(?, 0))",
              r.recovery_attempts
            ),
          recovery_outcome: fragment("COALESCE(EXCLUDED.recovery_outcome, ?)", r.recovery_outcome),
          recovery_repaired: fragment("COALESCE(EXCLUDED.recovery_repaired, ?)", r.recovery_repaired),
          recovery_token_usage:
            fragment(
              "CASE WHEN jsonb_strip_nulls(EXCLUDED.recovery_token_usage) = '{}'::jsonb THEN ? ELSE EXCLUDED.recovery_token_usage END",
              r.recovery_token_usage
            ),
          cold_check: fragment("COALESCE(NULLIF(EXCLUDED.cold_check, '{}'::jsonb), ?)", r.cold_check),
          approved_then_found_red:
            fragment("COALESCE(NULLIF(EXCLUDED.approved_then_found_red, '{}'::jsonb), ?)", r.approved_then_found_red)
        ]
      ]
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
          case decode_binary_payload(payload) do
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
      {limit, filters} = Harness.ResultStore.pop_limit(filters)
      {include_transcripts?, filters} = Keyword.pop(filters, :include_transcripts, false)
      point_lookup? = Keyword.has_key?(filters, :run_id)
      retain_outputs? = point_lookup? or include_transcripts?

      query =
        from r in RunRecordSchema,
          order_by: [desc: r.inserted_at]

      query = apply_filters(query, filters)
      query = if retain_outputs?, do: query, else: select_without_agent_output(query)
      query = if limit, do: limit(query, ^limit), else: query

      rows = repo.all(query)
      {:ok, Enum.map(rows, &row_to_log_record/1)}
    rescue
      e -> {:error, e}
    end
  end

  @impl Harness.ResultStore
  @spec delete_run(String.t(), keyword()) :: :ok | {:error, term()}
  def delete_run(run_id, opts) when is_binary(run_id) and is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)

    try do
      # delete_all is idempotent: a 0-row delete (absent run_id) still returns :ok.
      {_count, _} = repo.delete_all(from(r in RunRecordSchema, where: r.run_id == ^run_id))
      :ok
    rescue
      e -> {:error, e}
    end
  end

  @impl Harness.ResultStore
  @spec mark_landed(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def mark_landed(run_id, sha, opts) when is_binary(run_id) and is_binary(sha) and is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)
    now = NaiveDateTime.utc_now(:microsecond)

    try do
      {_count, _result} =
        repo.update_all(
          from(r in RunRecordSchema, where: r.run_id == ^run_id),
          set: [landed_sha: sha, updated_at: now]
        )

      :ok
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

  @impl Harness.ResultStore
  @spec aggregate_reviewer_reliability(keyword(), keyword()) ::
          {:ok, AgentKPI.reviewer_ledger()} | {:error, term()}
  def aggregate_reviewer_reliability(_query_opts, opts) when is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)

    try do
      rows = repo.all(aggregate_reviewer_reliability_query())
      {:ok, reviewer_rows_to_ledger(rows)}
    rescue
      e -> {:error, e}
    end
  end

  @impl Harness.ResultStore
  @spec aggregate_by_facet(keyword(), keyword()) :: {:ok, [Harness.ResultStore.facet_group()]} | {:error, term()}
  def aggregate_by_facet(_query_opts, opts) when is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)

    try do
      rows = repo.all(aggregate_by_facet_query())
      {:ok, facet_rows_to_groups(rows)}
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
        pass_count: r.run_id |> count() |> filter(r.verdict == "approve"),
        first_attempt_pass_count:
          r.run_id |> count() |> filter(r.verdict == "approve" and coalesce(r.review_iterations, 0) == 0),
        # review_stuck runs: the reason jsonb roundtrips a tuple as
        # {"$tuple": [{"$atom": "review_stuck"}, "..."]} (see encode_term/1).
        reviewer_flaked_count:
          r.run_id
          |> count()
          |> filter(fragment("(?->'$tuple'->0->>'$atom') = 'review_stuck'", r.reason)),
        durations: fragment("array_agg(? ORDER BY ?)", r.duration_ms, r.duration_ms),
        review_iterations_mean: avg(coalesce(r.review_iterations, 0)),
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
        pass_count_for_cost: r.run_id |> count() |> filter(r.verdict == "approve"),
        cost_to_green_mean:
          "coalesce((?->>'total')::float, 0)"
          |> fragment(r.token_usage)
          |> avg()
          |> filter(r.verdict == "approve"),
        # Collect each run's current + legacy quality blocks; the field fallback
        # and per-key means are computed in Elixir so Memory and Postgres share
        # the exact AgentKPI rollup.
        ratings:
          fragment(
            "array_agg(jsonb_build_object('review_skills', ?, 'review_ratings', ?))",
            r.review_skills,
            r.review_ratings
          )
      }
  end

  @spec aggregate_reviewer_reliability_query() :: Ecto.Query.t()
  defp aggregate_reviewer_reliability_query do
    from r in RunRecordSchema,
      where:
        not is_nil(r.reviewer_adapter) and
          (r.verdict in ["approve", "reject"] or
             fragment("(?->'$tuple'->0->>'$atom') = 'review_stuck'", r.reason)),
      group_by: [r.reviewer_adapter, r.reviewer_model],
      select: %{
        reviewer_adapter: r.reviewer_adapter,
        reviewer_model: r.reviewer_model,
        reviewed_count: count(r.run_id),
        rejection_count: r.run_id |> count() |> filter(r.verdict == "reject"),
        no_verdict_count:
          r.run_id
          |> count()
          |> filter(fragment("(?->'$tuple'->0->>'$atom') = 'review_stuck'", r.reason)),
        false_approval_count:
          r.run_id
          |> count()
          |> filter(
            fragment(
              "COALESCE(jsonb_typeof(?), '') = 'object' AND ? <> '{}'::jsonb",
              r.approved_then_found_red,
              r.approved_then_found_red
            )
          )
      }
  end

  @spec reviewer_rows_to_ledger([map()]) :: AgentKPI.reviewer_ledger()
  defp reviewer_rows_to_ledger(rows) do
    rows
    |> Enum.group_by(& &1.reviewer_adapter)
    |> Map.new(fn {reviewer_adapter, reviewer_rows} ->
      {string_to_module(reviewer_adapter), summarize_reviewer_rows(reviewer_rows)}
    end)
  end

  @spec summarize_reviewer_rows([map()]) :: AgentKPI.reviewer_rejection()
  defp summarize_reviewer_rows(rows) do
    reviewed_count = sum_rows(rows, :reviewed_count)
    rejection_count = sum_rows(rows, :rejection_count)
    no_verdict_count = sum_rows(rows, :no_verdict_count)
    false_approval_count = sum_rows(rows, :false_approval_count)

    %{
      reviewed_count: reviewed_count,
      rejection_count: rejection_count,
      rejection_rate: safe_rate(rejection_count, reviewed_count),
      no_verdict_count: no_verdict_count,
      no_verdict_rate: safe_rate(no_verdict_count, reviewed_count),
      false_approval_count: false_approval_count,
      false_approval_rate: safe_rate(false_approval_count, reviewed_count),
      by_model: Map.new(rows, &reviewer_model_row/1)
    }
  end

  @spec reviewer_model_row(map()) :: {String.t() | nil, map()}
  defp reviewer_model_row(row) do
    reviewed_count = row.reviewed_count || 0
    rejection_count = row.rejection_count || 0
    no_verdict_count = row.no_verdict_count || 0
    false_approval_count = row.false_approval_count || 0

    {row.reviewer_model,
     %{
       reviewed_count: reviewed_count,
       rejection_count: rejection_count,
       rejection_rate: safe_rate(rejection_count, reviewed_count),
       no_verdict_count: no_verdict_count,
       no_verdict_rate: safe_rate(no_verdict_count, reviewed_count),
       false_approval_count: false_approval_count,
       false_approval_rate: safe_rate(false_approval_count, reviewed_count)
     }}
  end

  @spec sum_rows([map()], atom()) :: non_neg_integer()
  defp sum_rows(rows, key), do: rows |> Enum.map(&(Map.get(&1, key) || 0)) |> Enum.sum()

  @spec aggregate_by_facet_query() :: Ecto.Query.t()
  defp aggregate_by_facet_query do
    rows =
      from r in RunRecordSchema,
        select: %{
          run_id: r.run_id,
          agent: r.agent,
          facet_json:
            fragment(
              "COALESCE((SELECT jsonb_object_agg(key, value ORDER BY key) FROM jsonb_each(COALESCE(?, '{}'::jsonb)) WHERE value IS NOT NULL AND value <> 'null'::jsonb), '{}'::jsonb)",
              r.review_facets
            ),
          verdict: r.verdict,
          reason: r.reason,
          duration_ms: r.duration_ms,
          review_iterations: r.review_iterations,
          token_usage: r.token_usage,
          review_skills: r.review_skills,
          review_ratings: r.review_ratings
        }

    from b in subquery(rows),
      group_by: [b.facet_json, b.agent],
      select: %{
        facet_json: b.facet_json,
        agent: b.agent,
        run_count: count(b.run_id),
        pass_count: b.run_id |> count() |> filter(b.verdict == "approve"),
        first_attempt_pass_count:
          b.run_id |> count() |> filter(b.verdict == "approve" and coalesce(b.review_iterations, 0) == 0),
        reviewer_flaked_count:
          b.run_id
          |> count()
          |> filter(fragment("(?->'$tuple'->0->>'$atom') = 'review_stuck'", b.reason)),
        durations: fragment("array_agg(? ORDER BY ?)", b.duration_ms, b.duration_ms),
        review_iterations_mean: avg(coalesce(b.review_iterations, 0)),
        input_mean:
          avg(
            fragment(
              "coalesce((?->>'input')::float, 0)",
              b.token_usage
            )
          ),
        output_mean:
          avg(
            fragment(
              "coalesce((?->>'output')::float, 0)",
              b.token_usage
            )
          ),
        total_mean:
          avg(
            fragment(
              "coalesce((?->>'total')::float, 0)",
              b.token_usage
            )
          ),
        pass_count_for_cost: b.run_id |> count() |> filter(b.verdict == "approve"),
        cost_to_green_mean:
          "coalesce((?->>'total')::float, 0)"
          |> fragment(b.token_usage)
          |> avg()
          |> filter(b.verdict == "approve"),
        ratings:
          fragment(
            "array_agg(jsonb_build_object('review_skills', ?, 'review_ratings', ?))",
            b.review_skills,
            b.review_ratings
          )
      }
  end

  @spec facet_rows_to_groups([map()]) :: [Harness.ResultStore.facet_group()]
  defp facet_rows_to_groups(rows) do
    rows
    |> Enum.group_by(& &1.facet_json)
    |> Enum.map(fn {_facet_json, agent_rows} ->
      facet = jsonb_to_facet_map(hd(agent_rows).facet_json)

      agents =
        Map.new(agent_rows, fn row ->
          {string_to_atom(row.agent), facet_agent_row_to_kpi(row)}
        end)

      %{facet: facet, agents: agents}
    end)
    |> Enum.sort_by(&Jason.encode!(Map.get(&1, :facet, %{})))
  end

  @spec facet_agent_row_to_kpi(map()) :: AgentKPI.agent_kpi()
  defp facet_agent_row_to_kpi(row) do
    run_count = row.run_count
    pass_count = row.pass_count || 0
    reviewer_flaked = row.reviewer_flaked_count || 0
    attributable_count = run_count - reviewer_flaked

    cost_to_green =
      if row.pass_count_for_cost > 0, do: float_or_nil(row.cost_to_green_mean)

    %{
      run_count: run_count,
      reviewer_flaked: reviewer_flaked,
      success_rate: safe_rate(pass_count, attributable_count),
      first_attempt_pass_rate: safe_rate(row.first_attempt_pass_count || 0, attributable_count),
      duration_ms: AgentKPI.duration_summary(row.durations || []),
      tokens: %{
        input: float_or_zero(row.input_mean),
        output: float_or_zero(row.output_mean),
        total: float_or_zero(row.total_mean)
      },
      review_iterations: float_or_zero(row.review_iterations_mean),
      ratings: row.ratings |> normalize_rating_records() |> AgentKPI.rating_means(),
      cost_to_green: cost_to_green
    }
  end

  @spec jsonb_to_facet_map(map() | nil) :: %{String.t() => term()}
  defp jsonb_to_facet_map(nil), do: %{}
  defp jsonb_to_facet_map(map) when is_map(map), do: map

  @spec aggregate_rows_to_ledger([map()]) :: AgentKPI.t()
  defp aggregate_rows_to_ledger(rows) do
    Map.new(rows, fn row ->
      run_count = row.run_count
      pass_count = row.pass_count || 0
      reviewer_flaked = row.reviewer_flaked_count || 0
      # Mirror AgentKPI.summarize/1: a review_stuck run is the reviewer's failure,
      # excluded from the implementer's success denominator (never run_count).
      attributable_count = run_count - reviewer_flaked

      cost_to_green =
        if row.pass_count_for_cost > 0, do: float_or_nil(row.cost_to_green_mean)

      kpi = %{
        run_count: run_count,
        reviewer_flaked: reviewer_flaked,
        success_rate: safe_rate(pass_count, attributable_count),
        first_attempt_pass_rate: safe_rate(row.first_attempt_pass_count || 0, attributable_count),
        duration_ms: AgentKPI.duration_summary(row.durations || []),
        tokens: %{
          input: float_or_zero(row.input_mean),
          output: float_or_zero(row.output_mean),
          total: float_or_zero(row.total_mean)
        },
        review_iterations: float_or_zero(row.review_iterations_mean),
        ratings: row.ratings |> normalize_rating_records() |> AgentKPI.rating_means(),
        cost_to_green: cost_to_green
      }

      {string_to_atom(row.agent), kpi}
    end)
  end

  # Zero attributable runs (every run reviewer-flaked) → 0.0, never a div-by-zero.
  @spec safe_rate(non_neg_integer(), non_neg_integer()) :: float()
  defp safe_rate(_count, 0), do: 0.0
  defp safe_rate(count, total), do: count / total

  @spec normalize_rating_records([map()] | nil) :: [map()]
  defp normalize_rating_records(nil), do: []
  defp normalize_rating_records(records), do: Enum.map(records, &AgentKPI.record_ratings/1)

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
        task_fingerprint: r.task_fingerprint,
        project_name: r.project_name,
        agent: r.agent,
        model: r.model,
        adapter: r.adapter,
        state: r.state,
        verdict: r.verdict,
        agent_outcome_kind: r.agent_outcome_kind,
        duration_ms: r.duration_ms,
        agent_diff_size: r.agent_diff_size,
        reviewer_diff_size: r.reviewer_diff_size,
        agent_exit_status: r.agent_exit_status,
        review_iterations: r.review_iterations,
        reviewer_reprompt_count: r.reviewer_reprompt_count,
        reviewer_rotation_count: r.reviewer_rotation_count,
        reviewer_adapter: r.reviewer_adapter,
        reviewer_model: r.reviewer_model,
        review_report: r.review_report,
        reviewer_outcome_kind: r.reviewer_outcome_kind,
        reviewer_exit_status: r.reviewer_exit_status,
        landed_sha: r.landed_sha,
        recovery_attempts: r.recovery_attempts,
        recovery_outcome: r.recovery_outcome,
        recovery_repaired: r.recovery_repaired,
        reason: r.reason,
        token_usage: r.token_usage,
        composed_inputs: r.composed_inputs,
        review_facets: r.review_facets,
        review_skills: r.review_skills,
        review_checks: r.review_checks,
        review_concerns: r.review_concerns,
        review_warning?: r.review_warning?,
        review_ratings: r.review_ratings,
        domains: r.domains,
        recovery_token_usage: r.recovery_token_usage,
        cold_check: r.cold_check,
        approved_then_found_red: r.approved_then_found_red,
        agent_output: type(^nil, :binary),
        reviewer_output: type(^nil, :binary),
        inserted_at: r.inserted_at,
        updated_at: r.updated_at
      }
  end

  # Payloads are harness-owned database blobs written by this store.
  # sobelow_skip ["Misc.BinToTerm"]
  @spec decode_binary_payload(binary()) :: {:ok, term()} | {:error, :invalid_term}
  defp decode_binary_payload(payload) do
    {:ok, :erlang.binary_to_term(payload)}
  rescue
    ArgumentError -> {:error, :invalid_term}
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
      task_fingerprint: r.task_fingerprint,
      project_name: r.project_name,
      agent: atom_or_string(r.agent),
      model: r.model,
      adapter: module_or_string(r.adapter),
      state: atom_or_string(r.state),
      verdict: atom_or_string(r.verdict),
      agent_outcome_kind: kind_to_string(r.agent_outcome_kind),
      duration_ms: r.duration_ms,
      agent_diff_size: r.agent_diff_size,
      reviewer_diff_size: r.reviewer_diff_size,
      agent_exit_status: r.agent_exit_status,
      review_iterations: r.review_iterations,
      reviewer_reprompt_count: r.reviewer_reprompt_count,
      reviewer_rotation_count: r.reviewer_rotation_count,
      reviewer_adapter: module_or_string(r.reviewer_adapter),
      reviewer_model: r.reviewer_model,
      review_report: r.review_report,
      reviewer_outcome_kind: kind_to_string(r.reviewer_outcome_kind),
      reviewer_exit_status: r.reviewer_exit_status,
      recovery_attempts: r.recovery_attempts,
      recovery_outcome: atom_or_string(r.recovery_outcome),
      recovery_repaired: r.recovery_repaired,
      landed_sha: r.landed_sha,
      reason: encode_jsonb(r.reason),
      token_usage: encode_jsonb(r.token_usage),
      composed_inputs: encode_jsonb(r.composed_inputs),
      review_facets: encode_jsonb(r.review_facets),
      review_skills: encode_jsonb(r.review_skills),
      review_checks: r.review_checks,
      review_concerns: encode_freeform_list(r.review_concerns),
      review_warning?: r.review_warning?,
      review_ratings: encode_jsonb(r.review_ratings),
      domains: encode_jsonb(r.domains),
      recovery_token_usage: encode_jsonb(r.recovery_token_usage),
      cold_check: r.cold_check,
      approved_then_found_red: r.approved_then_found_red,
      agent_output: r.agent_output,
      reviewer_output: r.reviewer_output
    }
  end

  @spec row_to_log_record(RunRecordSchema.t()) :: LogRecord.t()
  defp row_to_log_record(%RunRecordSchema{} = row) do
    %LogRecord{
      batch_id: row.batch_id,
      run_id: row.run_id,
      task_id: row.task_id,
      task_fingerprint: row.task_fingerprint,
      project_name: row.project_name,
      agent: string_to_atom(row.agent),
      model: row.model,
      adapter: string_to_module(row.adapter),
      state: string_to_atom(row.state),
      reason: decode_jsonb(row.reason),
      verdict: string_to_atom(row.verdict),
      duration_ms: default(row.duration_ms, 0),
      agent_diff_size: row.agent_diff_size,
      reviewer_diff_size: row.reviewer_diff_size,
      review_iterations: default(row.review_iterations, 0),
      reviewer_reprompt_count: default(row.reviewer_reprompt_count, 0),
      reviewer_rotation_count: default(row.reviewer_rotation_count, 0),
      reviewer_adapter: string_to_module(row.reviewer_adapter),
      reviewer_model: row.reviewer_model,
      review_report: row.review_report,
      review_facets: decode_freeform_block(row.review_facets),
      review_skills: decode_freeform_block(row.review_skills),
      review_checks: decode_freeform_block(row.review_checks),
      review_concerns: decode_freeform_list(row.review_concerns),
      review_warning?: default(row.review_warning?, false),
      review_ratings: decode_review_ratings(row.review_ratings),
      token_usage: decode_token_usage(row.token_usage),
      composed_inputs: default(decode_jsonb(row.composed_inputs), []),
      agent_outcome_kind: string_to_kind(row.agent_outcome_kind),
      agent_exit_status: row.agent_exit_status,
      agent_output: default(row.agent_output, ""),
      reviewer_outcome_kind: string_to_kind(row.reviewer_outcome_kind),
      reviewer_exit_status: row.reviewer_exit_status,
      reviewer_output: default(row.reviewer_output, ""),
      domains: default(decode_jsonb(row.domains), []),
      recovery_attempts: default(row.recovery_attempts, 0),
      recovery_outcome: string_to_atom(row.recovery_outcome),
      recovery_repaired: row.recovery_repaired,
      recovery_token_usage: decode_token_usage(row.recovery_token_usage),
      landed_sha: row.landed_sha,
      cold_check: decode_optional_freeform_block(row.cold_check),
      approved_then_found_red: decode_freeform_block(row.approved_then_found_red)
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

  # agent_outcome_kind is Outcome.kind(): :exited or a tagged tuple such as
  # {:timed_out, :idle}. The column is :string, so tuple kinds serialize as
  # JSON text via the same $-marker scheme the jsonb columns use; bare atoms
  # stay plain strings (back-compat with rows written before the codec).
  @spec kind_to_string(Outcome.kind() | nil) :: String.t() | nil
  defp kind_to_string(nil), do: nil
  defp kind_to_string(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp kind_to_string(kind) when is_tuple(kind), do: Jason.encode!(encode_term(kind))

  @spec string_to_kind(String.t() | nil) :: Outcome.kind() | nil
  defp string_to_kind(nil), do: nil
  defp string_to_kind("{" <> _ = json), do: decode_term(Jason.decode!(json))
  defp string_to_kind(s) when is_binary(s), do: string_to_atom(s)

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

  # review_ratings' outer keys are rating-name strings (LogRecord.review_ratings
  # type); decode values only — the outer keys must never be atomized.
  @spec decode_review_ratings(map() | nil) :: %{optional(String.t()) => term()}
  defp decode_review_ratings(nil), do: %{}

  defp decode_review_ratings(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, decode_term(v)} end)
  end

  # facets/skills are reviewer-authored, open-vocabulary JSON (Task 224): free-form
  # string keys at every level, never a closed enum. They are stored verbatim and
  # must read back verbatim — atomizing any key would lose fidelity (and trip the
  # DOS.StringToAtom guard on untrusted input). jsonb already returns string-keyed
  # maps, so the read is a straight passthrough.
  @spec decode_freeform_block(map() | nil) :: %{optional(String.t()) => term()}
  defp decode_freeform_block(nil), do: %{}
  defp decode_freeform_block(map) when is_map(map), do: map

  @spec decode_optional_freeform_block(map() | nil) :: %{optional(String.t()) => term()} | nil
  defp decode_optional_freeform_block(nil), do: nil
  defp decode_optional_freeform_block(map) when is_map(map), do: map

  @spec encode_freeform_list([term()]) :: map()
  defp encode_freeform_list(list) when is_list(list), do: %{"$list" => list}

  @spec decode_freeform_list(map() | nil) :: [term()]
  defp decode_freeform_list(nil), do: []
  defp decode_freeform_list(%{"$list" => list}) when is_list(list), do: list
  defp decode_freeform_list(_other), do: []

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

  # --- test helper: expose sandbox checkout for DataCase consumers ---
  @doc false
  @spec ensure_sandbox() :: :ok
  def ensure_sandbox do
    # No-op marker; real checkout lives in Harness.DataCase
    :ok
  end
end
