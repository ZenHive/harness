defmodule Harness.ResultStore do
  @moduledoc """
  Pluggable persistence boundary for run logs and batch results.

  The core orchestrator talks only to this behaviour. Defaults follow
  `:repo_enabled`: Postgres for durable deployments, in-memory ephemeral storage
  when the repo is disabled, unless callers explicitly configure another store.

  ## Best-effort persistence

  Persistence is **best-effort**: `Harness.Run` and `Harness.Batch` invoke
  `record_run/2` and `save_batch/2` on the configured store at settle time,
  log any `{:error, _}` via `Logger.warning/1`, and continue. Neither a
  failed `record_run` nor a failed `save_batch` crashes the run or flips
  `Harness.Batch.run/4`'s `{:ok, result}` to `{:error, _}`. Treat a missing
  record as a degraded observability surface, not a missing verdict —
  verdicts come from the reviewer AI's `.harness/review.json` artifact
  (`Harness.Run.Review`), not the store.

  Set `config :harness, :result_store, false` (or `nil`) to disable
  persistence entirely; both values short-circuit `record_run`, `save_batch`,
  `load_batch`, `list_run_records`, and `delete_run` without dispatching to a
  backend.
  """

  use Descripex, namespace: "/result_store"

  alias Harness.AgentKPI
  alias Harness.Batch.Result, as: BatchResult
  alias Harness.CapabilityScore.Legacy, as: CapabilityScore
  alias Harness.Git
  alias Harness.Project
  alias Harness.Run.LogRecord
  alias Harness.Run.Status

  @run_branch_prefix "harness/"

  @typedoc "A configured result store module, with optional module-specific options."
  @type store :: module() | {module(), keyword()} | nil | false

  @typedoc "Exact-match filters supported by `list_run_records/2`."
  @type filters :: keyword()

  @configured_store :configured_result_store

  @doc "Persists one structured run record with implementation-specific options."
  @callback record_run(LogRecord.t(), keyword()) :: :ok | {:error, term()}

  @doc "Persists one finished batch result with implementation-specific options."
  @callback save_batch(BatchResult.t(), keyword()) :: :ok | {:error, term()}

  @doc "Loads one persisted batch result by id."
  @callback load_batch(String.t(), keyword()) :: {:ok, BatchResult.t()} | {:error, term()}

  @doc "Lists persisted run records, optionally filtered by exact field values."
  @callback list_run_records(filters(), keyword()) :: {:ok, [LogRecord.t()]} | {:error, term()}

  @doc "Deletes one persisted run record by id. Idempotent — an absent record returns :ok."
  @callback delete_run(String.t(), keyword()) :: :ok | {:error, term()}

  @doc """
  Rolls persisted run records up into a per-agent KPI ledger (`Harness.AgentKPI.t/0`).

  Backends with SQL fast paths (Postgres) issue one aggregate query; others fall
  back to `list_run_records/1` + `Harness.AgentKPI.aggregate/1`.
  """
  @callback aggregate_by_agent(keyword(), keyword()) :: {:ok, AgentKPI.t()} | {:error, term()}

  @doc "Persists one computed capability score."
  @callback save_capability_score(CapabilityScore.t(), keyword()) :: :ok | {:error, term()}

  @doc "Loads one persisted capability score cell, or returns :no_data when unmeasured."
  @callback get_capability_score(atom(), atom(), String.t(), keyword()) ::
              {:ok, CapabilityScore.t()} | :no_data | {:error, term()}

  @doc "Lists persisted capability scores for routing and re-benchmark planning."
  @callback list_capability_scores(keyword()) :: {:ok, [CapabilityScore.t()]} | {:error, term()}

  api(
    :record_run,
    "Persist one structured run record. Best-effort — failures log and return {:error, _} but never crash the run.",
    params: [
      record: [
        kind: :value,
        description: "%Harness.Run.LogRecord{} the caller built from a settled run's result."
      ],
      store: [
        kind: :value,
        default: nil,
        description:
          "Configured store from ResultStore.configured/0 (defaults), or {module, opts} override, or `false`/`nil` to short-circuit. Caller-supplied."
      ]
    ],
    returns: %{type: :tuple, description: ":ok or {:error, reason} from the backing store."}
  )

  @spec record_run(LogRecord.t(), store()) :: :ok | {:error, term()}
  def record_run(record, store \\ configured())

  def record_run(%LogRecord{}, false), do: :ok
  def record_run(%LogRecord{}, nil), do: :ok

  def record_run(%LogRecord{} = record, store) do
    dispatch(store, :record_run, [record])
  end

  api(:save_batch, "Persist the aggregate result for a finished batch. Best-effort.",
    params: [
      result: [
        kind: :value,
        description: "%Harness.Batch.Result{} returned by Harness.Batch.run/4."
      ],
      store: [
        kind: :value,
        default: nil,
        description: "Configured store from ResultStore.configured/0, or override; `false`/`nil` short-circuits."
      ]
    ],
    returns: %{type: :tuple, description: ":ok or {:error, reason} from the backing store."}
  )

  @spec save_batch(BatchResult.t(), store()) :: :ok | {:error, term()}
  def save_batch(result, store \\ configured())

  def save_batch(%BatchResult{}, false), do: :ok
  def save_batch(%BatchResult{}, nil), do: :ok

  def save_batch(%BatchResult{} = result, store) do
    dispatch(store, :save_batch, [result])
  end

  api(:load_batch, "Load a previously persisted batch result by id.",
    params: [
      batch_id: [kind: :value, description: "Batch id string assigned at dispatch time."],
      store: [
        kind: :value,
        default: @configured_store,
        description:
          "Configured store from ResultStore.configured/0 when omitted, or override; `false`/`nil` returns {:error, :disabled}."
      ]
    ],
    returns: %{type: :tuple, description: "{:ok, %Harness.Batch.Result{}} or {:error, reason}."}
  )

  @spec load_batch(String.t(), store()) :: {:ok, BatchResult.t()} | {:error, term()}
  def load_batch(batch_id, store \\ configured())

  def load_batch(batch_id, @configured_store) when is_binary(batch_id), do: load_batch(batch_id, configured())
  def load_batch(batch_id, false) when is_binary(batch_id), do: {:error, :disabled}
  def load_batch(batch_id, nil) when is_binary(batch_id), do: {:error, :disabled}

  def load_batch(batch_id, store) when is_binary(batch_id) do
    dispatch(store, :load_batch, [batch_id])
  end

  api(
    :list_run_records,
    "List persisted run records, optionally filtered by exact field values (run_id, batch_id, agent, adapter, verdict).",
    params: [
      filters: [
        kind: :value,
        default: [],
        description:
          "Keyword filter list — exact-match field values supported by the store backend. Common keys: run_id, batch_id, agent, adapter, verdict, :limit (max rows, newest-first). List queries omit transcript binaries unless run_id pins a single row. The 2-arity overload list_run_records(store, filters) is an internal escape hatch — prefer the 1-arity form and configure the store via config :harness, :result_store."
      ]
    ],
    returns: %{type: :tuple, description: "{:ok, [LogRecord.t()]} or {:error, reason}."}
  )

  @spec list_run_records(filters()) :: {:ok, [LogRecord.t()]} | {:error, term()}
  def list_run_records(filters \\ []) when is_list(filters) do
    list_run_records(configured(), filters)
  end

  @doc false
  @spec list_run_records(store(), filters()) :: {:ok, [LogRecord.t()]} | {:error, term()}
  def list_run_records(false, filters) when is_list(filters), do: {:ok, []}
  def list_run_records(nil, filters) when is_list(filters), do: {:ok, []}

  def list_run_records(store, filters) when is_list(filters) do
    dispatch(store, :list_run_records, [filters])
  end

  # Dashboard-only reconciliation helper, deliberately not exposed through the
  # Descripex API surface.
  @doc false
  @spec landed_sha(LogRecord.t() | Status.t(), Project.t()) :: String.t() | nil
  def landed_sha(%LogRecord{run_id: run_id}, %Project{} = project), do: landed_sha_for_run(run_id, project)
  def landed_sha(%Status{run_id: run_id}, %Project{} = project), do: landed_sha_for_run(run_id, project)

  # Deliberately NOT api()-annotated: ResultStore is in the Manifest driver
  # surface, so an api() here would expose a destructive write to the orchestrator
  # MCP/chat tool list. delete_run is dashboard-operator cleanup (the run-history
  # Delete button calls it directly); keep it off the agent surface until an
  # orchestrator use case asks for it (then it's a one-line api/3 add).
  @doc false
  @spec delete_run(String.t(), store()) :: :ok | {:error, term()}
  def delete_run(run_id, store \\ configured())

  def delete_run(run_id, false) when is_binary(run_id), do: :ok
  def delete_run(run_id, nil) when is_binary(run_id), do: :ok

  def delete_run(run_id, store) when is_binary(run_id) do
    dispatch(store, :delete_run, [run_id])
  end

  api(
    :aggregate_by_agent,
    "Per-agent KPI ledger over all persisted run records (one aggregate query on Postgres).",
    params: [
      store: [
        kind: :value,
        default: @configured_store,
        description:
          "Configured store from ResultStore.configured/0 when omitted, or override; `false`/`nil` returns {:ok, %{}}."
      ]
    ],
    returns: %{type: :tuple, description: "{:ok, AgentKPI.t()} or {:error, reason}."}
  )

  @spec aggregate_by_agent(store()) :: {:ok, AgentKPI.t()} | {:error, term()}
  def aggregate_by_agent(store \\ configured())

  def aggregate_by_agent(@configured_store), do: aggregate_by_agent(configured())
  def aggregate_by_agent(false), do: {:ok, %{}}
  def aggregate_by_agent(nil), do: {:ok, %{}}

  def aggregate_by_agent(store) do
    dispatch(store, :aggregate_by_agent, [[]])
  end

  api(
    :aggregate_reviewer_reliability,
    "Per-reviewer-adapter reliability ledger over all persisted run records: rejection_rate and no_verdict_rate (review_stuck — the reviewer gated the run but wrote no verdict). Derived from list_run_records; no SQL fast path.",
    params: [
      store: [
        kind: :value,
        default: @configured_store,
        description:
          "Configured store from ResultStore.configured/0 when omitted, or override; `false`/`nil` returns {:ok, %{}}."
      ]
    ],
    returns: %{type: :tuple, description: "{:ok, AgentKPI.reviewer_ledger()} or {:error, reason}."}
  )

  @spec aggregate_reviewer_reliability(store()) :: {:ok, AgentKPI.reviewer_ledger()} | {:error, term()}
  def aggregate_reviewer_reliability(store \\ configured())

  def aggregate_reviewer_reliability(@configured_store), do: aggregate_reviewer_reliability(configured())
  def aggregate_reviewer_reliability(false), do: {:ok, %{}}
  def aggregate_reviewer_reliability(nil), do: {:ok, %{}}

  def aggregate_reviewer_reliability(store) do
    case list_run_records(store, []) do
      {:ok, records} -> {:ok, AgentKPI.aggregate_reviewer_rejections(records)}
      {:error, _} = err -> err
    end
  end

  api(
    :aggregate_review_stuck_causes,
    "Orchestration-health review_stuck counts by persisted cause, including selection-time stuck runs with no reviewer_adapter. Derived from list_run_records; no attribution to implementers or reviewers.",
    params: [
      store: [
        kind: :value,
        default: @configured_store,
        description:
          "Configured store from ResultStore.configured/0 when omitted, or override; `false`/`nil` returns {:ok, %{}}."
      ]
    ],
    returns: %{type: :tuple, description: "{:ok, AgentKPI.review_stuck_causes()} or {:error, reason}."}
  )

  @spec aggregate_review_stuck_causes(store()) :: {:ok, AgentKPI.review_stuck_causes()} | {:error, term()}
  def aggregate_review_stuck_causes(store \\ configured())

  def aggregate_review_stuck_causes(@configured_store), do: aggregate_review_stuck_causes(configured())
  def aggregate_review_stuck_causes(false), do: {:ok, %{}}
  def aggregate_review_stuck_causes(nil), do: {:ok, %{}}

  def aggregate_review_stuck_causes(store) do
    case list_run_records(store, []) do
      {:ok, records} -> {:ok, AgentKPI.aggregate_review_stuck_causes(records)}
      {:error, _} = err -> err
    end
  end

  api(
    :aggregate_ceremony_cost,
    "Per-run ceremony token facts over reviewer-approved runs: implementer + reviewer + audit (audit is 0 until audit capture lands). Raw median/p90 distribution only — no batching verdict.",
    params: [
      opts: [
        kind: :value,
        default: [],
        description:
          "Options keyword. `:limit` (default 200) caps recent runs scanned (newest-first). Reviewer spend requires reviewer_output — this query sets include_transcripts internally."
      ],
      store: [
        kind: :value,
        default: @configured_store,
        description:
          "Configured store from ResultStore.configured/0 when omitted, or override; `false`/`nil` returns an empty ceremony_cost map."
      ]
    ],
    returns: %{
      type: :tuple,
      description: "{:ok, AgentKPI.ceremony_cost()} or {:error, reason}."
    }
  )

  @spec aggregate_ceremony_cost(keyword(), store()) :: {:ok, AgentKPI.ceremony_cost()} | {:error, term()}
  def aggregate_ceremony_cost(opts \\ [], store \\ configured())

  def aggregate_ceremony_cost(opts, @configured_store) when is_list(opts), do: aggregate_ceremony_cost(opts, configured())
  def aggregate_ceremony_cost(opts, false) when is_list(opts), do: {:ok, AgentKPI.aggregate_ceremony_cost([])}
  def aggregate_ceremony_cost(opts, nil) when is_list(opts), do: {:ok, AgentKPI.aggregate_ceremony_cost([])}

  def aggregate_ceremony_cost(opts, store) when is_list(opts) do
    limit = Keyword.get(opts, :limit, 200)
    filters = [include_transcripts: true, limit: limit]

    case list_run_records(store, filters) do
      {:ok, records} -> {:ok, AgentKPI.aggregate_ceremony_cost(records)}
      {:error, _} = err -> err
    end
  end

  api(:save_capability_score, "Persist one computed capability score.",
    params: [
      score: [
        kind: :value,
        description:
          "%Harness.CapabilityScore{} computed from AgentEvaluation comparisons, including retained raw metrics."
      ],
      store: [
        kind: :value,
        default: nil,
        description: "Configured store from ResultStore.configured/0, or override; `false`/`nil` short-circuits."
      ]
    ],
    returns: %{type: :tuple, description: ":ok or {:error, reason} from the backing store."}
  )

  @spec save_capability_score(CapabilityScore.t(), store()) :: :ok | {:error, term()}
  def save_capability_score(score, store \\ configured())

  def save_capability_score(%CapabilityScore{}, false), do: :ok
  def save_capability_score(%CapabilityScore{}, nil), do: :ok

  def save_capability_score(%CapabilityScore{} = score, store) do
    dispatch(store, :save_capability_score, [score])
  end

  api(:get_capability_score, "Load one persisted capability score cell, returning :no_data when unmeasured.",
    params: [
      agent: [kind: :value, description: "Agent atom, e.g. :codex."],
      domain: [kind: :value, description: "Capability domain atom, e.g. :ecto."],
      corpus_version: [kind: :value, description: "Corpus version fingerprint or caller-supplied version string."],
      store: [
        kind: :value,
        default: @configured_store,
        description:
          "Configured store from ResultStore.configured/0 when omitted, or override; `false`/`nil` returns :no_data."
      ]
    ],
    returns: %{
      type: :tuple,
      description: "{:ok, %Harness.CapabilityScore{}} when measured, :no_data when absent, or {:error, reason}."
    }
  )

  @spec get_capability_score(atom(), atom(), String.t(), store()) ::
          {:ok, CapabilityScore.t()} | :no_data | {:error, term()}
  def get_capability_score(agent, domain, corpus_version, store \\ configured())

  def get_capability_score(agent, domain, corpus_version, @configured_store)
      when is_atom(agent) and is_atom(domain) and is_binary(corpus_version),
      do: get_capability_score(agent, domain, corpus_version, configured())

  def get_capability_score(agent, domain, corpus_version, false)
      when is_atom(agent) and is_atom(domain) and is_binary(corpus_version), do: :no_data

  def get_capability_score(agent, domain, corpus_version, nil)
      when is_atom(agent) and is_atom(domain) and is_binary(corpus_version), do: :no_data

  def get_capability_score(agent, domain, corpus_version, store)
      when is_atom(agent) and is_atom(domain) and is_binary(corpus_version) do
    dispatch(store, :get_capability_score, [agent, domain, corpus_version])
  end

  api(:list_capability_scores, "List persisted capability score cells for routing and re-benchmark planning.",
    params: [
      store: [
        kind: :value,
        default: @configured_store,
        description:
          "Configured store from ResultStore.configured/0 when omitted, or override; `false`/`nil` returns {:ok, []}."
      ]
    ],
    returns: %{
      type: :tuple,
      description: "{:ok, [%Harness.CapabilityScore{}]} or {:error, reason}."
    }
  )

  @spec list_capability_scores(store()) :: {:ok, [CapabilityScore.t()]} | {:error, term()}
  def list_capability_scores(store \\ configured())

  def list_capability_scores(@configured_store), do: list_capability_scores(configured())
  def list_capability_scores(false), do: {:ok, []}
  def list_capability_scores(nil), do: {:ok, []}

  def list_capability_scores(store) do
    dispatch(store, :list_capability_scores, [])
  end

  api(:configured, "Return the configured result store, defaulting from :repo_enabled.",
    returns: %{
      type: :term,
      description: "store() — module() | {module(), keyword()} | nil | false. From config :harness, :result_store."
    }
  )

  @spec configured() :: store()
  def configured do
    case Application.get_env(:harness, :result_store) do
      nil ->
        if Application.get_env(:harness, :repo_enabled, true) do
          {Harness.ResultStore.Postgres, []}
        else
          {Harness.ResultStore.Memory, []}
        end

      store ->
        store
    end
  end

  # Pops a positive-integer `:limit` from `filters`, returning `{limit, rest}`.
  # Shared by the Memory and Postgres backends so the "newest-N rows" cap parses
  # identically: a non-positive or non-integer `:limit` is treated as absent
  # (`{nil, rest}`) rather than rejected. Backend-internal (`@doc false`).
  @doc false
  @spec pop_limit(filters()) :: {pos_integer() | nil, filters()}
  def pop_limit(filters) when is_list(filters) do
    case Keyword.pop(filters, :limit) do
      {limit, rest} when is_integer(limit) and limit > 0 -> {limit, rest}
      {_absent_or_bad, rest} -> {nil, rest}
    end
  end

  @spec dispatch(module() | {module(), keyword()}, atom(), [term()]) :: term()
  defp dispatch({module, opts}, function, args) when is_atom(module) and is_list(opts) do
    apply(module, function, args ++ [opts])
  end

  defp dispatch(module, function, args) when is_atom(module) do
    apply(module, function, args ++ [[]])
  end

  # Local-refs-only landed detection — NO network fetch. The lander keeps the
  # shared `origin/<target>` remote-tracking ref fresh via its own fetch/push,
  # so render/cold-path callers consult it directly. A `git fetch` here would put
  # blocking network I/O on the (formerly per-row) read path — the task-244 hang.
  @spec landed_sha_for_run(String.t(), Project.t()) :: String.t() | nil
  defp landed_sha_for_run(run_id, %Project{target_branch: target} = project)
       when is_binary(run_id) and run_id != "" and is_binary(target) and target != "" do
    case Project.local_repo_path(project) do
      {:ok, repo} ->
        target_ref = "origin/" <> target
        reachable_branch_sha(repo, run_id, target_ref) || logged_run_sha(repo, run_id, target_ref)

      _reason ->
        nil
    end
  end

  defp landed_sha_for_run(_run_id, %Project{}), do: nil

  @spec reachable_branch_sha(String.t(), String.t(), String.t()) :: String.t() | nil
  defp reachable_branch_sha(repo, run_id, target_ref) do
    branch = @run_branch_prefix <> run_id

    with {:ok, sha} <- rev_parse(repo, branch),
         true <- ancestor?(repo, sha, target_ref) do
      sha
    else
      _reason -> nil
    end
  end

  @spec logged_run_sha(String.t(), String.t(), String.t()) :: String.t() | nil
  defp logged_run_sha(repo, run_id, target_ref) do
    pattern = "(run #{run_id})"

    case Git.run(["log", "--format=%H", "--fixed-strings", "--grep", pattern, "-n", "1", target_ref], repo) do
      {:ok, output} -> output |> String.split("\n", trim: true) |> List.first()
      {:error, _reason} -> nil
    end
  end

  @spec rev_parse(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp rev_parse(repo, ref) do
    case Git.run(["rev-parse", "--verify", "--quiet", ref <> "^{commit}"], repo) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, _reason} = error -> error
    end
  end

  @spec ancestor?(String.t(), String.t(), String.t()) :: boolean()
  defp ancestor?(repo, maybe_ancestor, descendant) do
    match?({:ok, _output}, Git.run(["merge-base", "--is-ancestor", maybe_ancestor, descendant], repo))
  end
end
