# harness — Performance Audit

Scope: Ecto/Postgres query patterns (`result_store`, `project_registry`, `settings_store`,
`chat/store`), OTP hot-path (agent-output capture / `AgentAdapter` Port handling), LiveView
dashboard, Oban queue config. Raw-passthrough (no agent-output parsing) is by design — not
flagged. Simple counters/sums are "counting facts" per project convention — not flagged unless
the counting itself is unbounded/unindexed at scale.

Findings are ranked by severity; each cites `file:line`.

---

## CRITICAL

### C1. Post-merge audit fetches every historical transcript blob in the project to find one row

`lib/harness/audit.ex:526-538` (`persist_cold_check/4` / `persist_matching_cold_check/4`):

```elixir
defp persist_cold_check(project, store, landed_sha, cold_check) do
  case ResultStore.list_run_records(store, project_name: project.name, include_transcripts: true) do
    {:ok, records} -> persist_matching_cold_check(records, store, landed_sha, cold_check)
    ...
  end
end

defp persist_matching_cold_check(records, store, landed_sha, cold_check) do
  case Enum.find(records, &(&1.landed_sha == landed_sha)) do
    ...
```

This runs on **every** post-merge audit job (`Harness.Audit.Worker`). It requests
`include_transcripts: true` with **no `:limit`**, which forces
`Harness.ResultStore.Postgres.list_run_records/2` (`lib/harness/result_store/postgres.ex:218-241`)
to skip `select_without_agent_output/1` and pull the full `agent_output` +
`reviewer_output` binary blobs for **every run record ever persisted for the project**,
transfers them over the wire, then does a linear `Enum.find/2` in Elixir to locate the one
row matching `landed_sha`. There is no `:landed_sha` filter option in `apply_filters/2`
(see C2/M1), so this can't be pushed into the `WHERE` clause even if desired. Cost grows
without bound as a project accumulates run history, and every audit re-pays the full
blob-transfer cost. Fix: add a `:landed_sha` filter to `apply_filters/2` (and an index,
see M1), and never pass `include_transcripts: true` for a scan whose only use is an
equality match.

### C2. `Harness.ResultStore.Postgres.apply_filters/2` silently drops the `:task_id` filter — a correctness/perf divergence between backends

`lib/harness/result_store/postgres.ex:721-734`:

```elixir
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
```

`Harness.Run.Worker.recoverable_run_record/2` (`lib/harness/run/worker.ex:677`) calls:

```elixir
ResultStore.list_run_records(project_name: project.name, task_id: item_id)
```

expecting task-scoped filtering (this is the `dispatch-resume_failed` / recovery
idempotency check, called on essentially every dispatch attempt whose run isn't already
live). Because `:task_id` has no clause in `apply_filters/2`, the `_ -> q` fallback
silently ignores it — Postgres returns **every** run record for the whole project (no
`:limit` is passed either), and the caller's `find_recoverable_record/3`
(`lib/harness/run/worker.ex:683-692`) then filters client-side by
`%LogRecord{task_id: ^item_id}`. Correctness is saved by the client-side pattern match, but
the query itself is an unbounded per-project full scan on a hot dispatch path, and it
diverges from `Harness.ResultStore.Memory.match_filters?/2`
(`lib/harness/result_store/memory.ex:204-207`), which filters generically by
`Map.get(record, key) == value` and so *does* filter by `task_id` correctly in-memory.
Tests running against the Memory backend will not catch this Postgres-only gap. Fix: add a
`:task_id` (and ideally `:task_fingerprint`) clause to `apply_filters/2`, back it with an
index (M1), and pass a `:limit`.

---

## HIGH

### H1. Fleet-wide KPI aggregates are unindexed full-table scans, recomputed on every settle across every open dashboard tab

`lib/harness/dashboard/kpi_live.ex:107-110`:

```elixir
def handle_info({:harness_run_settled, %Status{}}, socket) do
  {:noreply, socket |> assign_rows() |> assign_facets()}
end
```

`assign_rows/1` (kpi_live.ex:126-141) and `assign_facets/1` (kpi_live.ex:219-236) together
issue five separate reads on **every single run settlement anywhere in the fleet**, for
**every connected `/harness/kpi` browser tab** (not scoped to the settling run's project):

- `ResultStore.aggregate_by_agent/0` → `aggregate_by_agent_query/0`
  (`lib/harness/result_store/postgres.ex:364-419`) — `group_by: r.agent` with no `WHERE`,
  full sequential scan.
- `ResultStore.aggregate_reviewer_reliability/0` → `aggregate_reviewer_reliability_query/0`
  (postgres.ex:421-449) — `where: not is_nil(reviewer_adapter) and (...)`, unindexed
  (see M1).
- `ResultStore.aggregate_review_stuck_causes/0` → `list_run_records(store, [])`
  (postgres.ex:360-365 via `ResultStore.aggregate_review_stuck_causes/1`,
  `lib/harness/result_store.ex:360-365`) — **no `:limit`**, full table.
- `ResultStore.aggregate_recovery_facts/0` → `list_run_records(store, [])`
  (`lib/harness/result_store.ex:388-393`) — **no `:limit`**, full table.
- `ResultStore.aggregate_by_facet/0` → `aggregate_by_facet_query/0` (postgres.ex:501-571) —
  per-row correlated `jsonb_each` subquery (see L1) plus a full scan.

None of the five have a time bound or a `LIMIT`. As `run_records` grows into the tens of
thousands of rows this becomes 5 full scans per settle event, multiplied by every open KPI
tab. Fix: at minimum add a `:limit`/recency window to the unbounded two, and consider
debouncing the fleet-wide recompute (e.g. only refresh on a slow tick, or scope by the
viewing operator's selected project) instead of firing on every settle.

### H2. Landed-sha reconciliation issues one `git fetch` per unlanded run instead of once per project

`lib/harness/dashboard/live.ex:499-527` (`reconcile_history_landed/4` /
`reconcile_history_entry/4`) calls `ResultStore.reconcile_landed_sha/4`
(`lib/harness/result_store.ex:247-260`) once per history row with `landed_sha == nil` and
state `:done`/`:failed`. That function's `fetch_target/2`
(`lib/harness/result_store.ex:474-482`) does:

```elixir
Git.run(["fetch", "origin", "+#{target}:#{ref}"], repo)
```

— a real `git fetch` from `origin` — with no dedup by project. `reconcile_history_landed/4`
runs at LiveView `mount/3` (live.ex:122) and again on **every** 30-second `:roadmap_tick`
(live.ex:305-316) for as long as any row stays unlanded. A project with N still-unmerged
history rows (capped at `@history_limit = 200`, live.ex:99) triggers **N redundant
identical fetches of the same ref**, synchronously, inside the LiveView process, blocking
that render — repeating forever every 30s until every row lands. Fix: fetch each
project's target ref once per reconciliation pass (memoize on `project_name`) before
iterating its rows, rather than once per run.

---

## MEDIUM

### M1. Missing indexes for columns actually queried on `run_records`

`priv/repo/migrations/20260602000000_add_run_records_and_batch_results.exs` creates indexes
only on `batch_id`, `agent`, `project_name`, `inserted_at`. No index exists for:

- `verdict` — filtered in `apply_filters/2` (`:verdict` clause, postgres.ex:729) and used in
  every `filter(r.verdict == "approve")` aggregate predicate.
- `reviewer_adapter` — the `WHERE not is_nil(reviewer_adapter)` + `GROUP BY` in
  `aggregate_reviewer_reliability_query/0` (postgres.ex:422-427).
- `task_id` / `task_fingerprint` — needed once C2 is fixed to add the `:task_id` filter
  clause; the recovery-lookup path is otherwise an unindexed scan even after the filter
  bug is corrected.
- `landed_sha` — needed once C1 is fixed to add a `:landed_sha` filter clause.

Given the full-scan aggregates in H1 already force a sequential scan regardless, these
indexes matter most for the point-lookup paths (C1, C2, `reconcile_landed_sha`) once those
filters are wired up.

### M2. Per-chunk full-buffer copy in the transcript pane, replicated per viewer

`lib/harness/dashboard/transcript.ex:139-145` (`append/3`):

```elixir
def append(buffer, bytes, chunk) when is_binary(buffer) and is_integer(bytes) and bytes >= 0 do
  chunk_bin = IO.iodata_to_binary(chunk)
  combined = buffer <> chunk_bin
  ...
```

Every single port output chunk triggers a full copy of the existing buffer (up to the
200 KiB cap, `@buffer_bytes`) via `buffer <> chunk_bin`, instead of an O(chunk-size)
append. This helper is shared by the producer (`Harness.Run` gen_statem's own snapshot
buffer) **and** every connected dashboard viewer's `Harness.Dashboard.Live`
`handle_info({:harness_transcript, ...})` (`lib/harness/dashboard/live.ex:354-364`) — so
for a long streaming run watched by multiple operators, the O(buffer_size) copy repeats
once per chunk per viewer. Bounded by the 200 KiB cap (not unbounded growth), but still an
avoidable O(n·k) cost where an iolist/rope accumulation (mirroring the driver's own
`acc = [acc, data]` pattern in `agent_adapter/driver.ex:187`) would be O(k).

### M3. `ProjectRegistry.lookup/1` performs a live Postgres round-trip per call; `list/0` batches, `lookup/1` doesn't

`lib/harness/project_registry.ex:142-148` (`lookup/1`) calls
`LandingSettings.overlay/1` (`lib/harness/landing/settings.ex:56-59`), which is a
single-element wrapper around `overlay_many/1` — i.e. every `lookup/1` call issues its own
`SettingsStore.fetch/1` (`lib/harness/settings_store.ex:26-27`), a live Postgres read with
no caching layer (`SettingsStore` has no cache — moduledoc confirms "no app-env overlay
cache"). By contrast `ProjectRegistry.list/0` (project_registry.ex:158-163) explicitly
batches to **one** fetch regardless of project count (documented at
`landing/settings.ex:61-66`: "Callers such as `ProjectRegistry.list/0` use this to issue
exactly one `SettingsStore.fetch/1`... Per-project `overlay/1` delegates here"). `lookup/1`
sits on hot paths — e.g. `Harness.Dashboard.Live.load_task_item/2`
(`lib/harness/dashboard/live.ex:232-241`) calls it on every run-detail page load — each
paying a DB round trip for a value (landing policy overrides) that changes rarely. Fix:
either cache the overrides in `ProjectRegistry`'s own GenServer state (invalidated on
write) or have `lookup/1` route through the same one-fetch-per-call machinery `list/0`
uses when looking up a single name.

---

## LOW

### L1. Per-row correlated `jsonb_each` subquery in the facet aggregate

`lib/harness/result_store/postgres.ex:501-521` (`aggregate_by_facet_query/0`) computes, in
the inner `select`, a correlated subquery per row:

```sql
COALESCE((SELECT jsonb_object_agg(key, value ORDER BY key) FROM jsonb_each(COALESCE(review_facets, '{}'::jsonb)) WHERE value IS NOT NULL AND value <> 'null'::jsonb), '{}'::jsonb)
```

This normalizes `review_facets` before grouping. It runs once per row of the already
full-scanned (H1) table, adding row-by-row JSON processing on top of the sequential scan.
Not a bug, but a compounding cost as the table grows — a candidate for pre-normalizing
`review_facets` at write time (`record_run/2`) instead of at every aggregate read.

### L2. Progress-watchdog fingerprint walks the whole worktree synchronously in the driver loop

`lib/harness/agent_adapter/watchdog.ex:295-321` (`edit_fingerprint/1` /
`file_fingerprints/1`) recursively lists and `stat`s every file in the run's worktree
(excluding `.git`) to build a progress-stall fingerprint. This only fires when the
progress deadline actually expires (default every 5 minutes, reset on each detected tool
call — `lib/harness/agent_adapter/watchdog.ex:83-89, 158-161`), so it is not a per-chunk
hot-path cost, but it is a synchronous, unbounded (in worktree file count) filesystem walk
executing inside the blocking `Harness.AgentAdapter.Driver` receive loop
(`lib/harness/agent_adapter/driver.ex`) — on a large monorepo worktree this could itself
approach or exceed typical progress-timeout windows.

---

## Not flagged (by design, per project convention)

- Raw agent-output passthrough (no parsing/normalization) — deliberate architecture.
- `Harness.AgentAdapter.Driver`'s `acc = [acc, data]` iodata accumulation
  (`lib/harness/agent_adapter/driver.ex:187`) — correct O(1)-per-chunk iolist growth, only
  materialized once via `IO.iodata_to_binary/1` at the end (`outcome/4`).
- `Harness.Dashboard.Live`'s `:active_runs` / `:history` tables already use
  `Phoenix.LiveView.stream/3` (bounded to `@history_limit = 200`) rather than plain assigns
  — correctly follows the streams-for-large-lists rule.
- `Harness.ProjectRegistry` and `Harness.Oban`'s per-project queue model (in-memory
  GenServer state seeded once from Postgres; `Oban.Plugins.Pruner` bounds the jobs table) —
  well-designed, no N+1 concerns found.
- `dep_freshness_snapshots` / `suite_health_results` — one row per project
  (`project_name` primary key), no scaling concern.

---

## Summary

5 real findings beyond nitpicks: 2 critical (unbounded full-blob project scan on every
post-merge audit; a silently-ignored filter that turns a task-scoped recovery lookup into
an unbounded per-project scan, diverging from the Memory backend's behavior), 2 high
(fleet-wide unindexed aggregate recompute fired by every settle across every open KPI tab;
redundant per-run `git fetch` instead of per-project), plus indexing gaps and smaller
per-chunk/per-call inefficiencies. Nothing here is an active outage — the system is
correct at today's data volumes — but every unbounded-query finding scales with run-history
growth and will visibly degrade the dashboard and audit/recovery paths as the fleet
accumulates history.

**Performance health score: 58/100**
