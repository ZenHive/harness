# Harness Performance Audit — 2026-08-25

Static analysis only (no app boot). Scope: Ecto query patterns, DB indexes, hot-path
allocation, GenServer bottlenecks, LiveView data handling, Oban config. Issues only;
clean areas get one line at the end.

---

## 1. Ecto query patterns

### H1 — HIGH · Full-table run-record loads on every KPI refresh, twice, per client
`lib/harness/result_store.ex:451` and `:479` — `aggregate_review_stuck_causes/1` and
`aggregate_recovery_facts/1` are implemented as `list_run_records(store, [])`: **no
limit**, every `run_records` row loaded, decoded through `row_to_log_record/1`
(jsonb → term codec per column) into `%LogRecord{}` structs, then folded in Elixir.
`lib/harness/dashboard/kpi_live.ex:127-141` calls both inside `assign_rows/1`, which
runs on mount **and on every `{:harness_run_settled, _}` PubSub event**
(`kpi_live.ex:108-110`) — so one settling wave of N runs triggers N × (2 full-table
loads + 3 full-table SQL aggregates) × connected-KPI-clients. Row count is unbounded
(retention nulls transcripts but never deletes rows; ledger is already 1,600+ runs
and grows per dispatch).

**Fix:** push both rollups into SQL (`GROUP BY` on the `reason->'$tuple'->0->>'$atom'`
cause / recovery columns — the store already does exactly this pattern in
`aggregate_reviewer_reliability_query/0`), and debounce the settled-event refresh
(e.g. `Process.send_after` coalescing 2–5 s) so a wave costs one recompute.

Same unbounded `list_run_records(store, [])` at `lib/harness/capability_score.ex:149`
(scout assessment input) — bound it (`limit:`) or aggregate in SQL.

### H2 — HIGH · ModelAvailability N+1 against Postgres-backed SettingsStore
`Harness.SettingsStore` has **no cache** — every `fetch/1` is a `Repo.get` +
`binary_to_term` (`lib/harness/settings_store.ex:27`, `settings_store/postgres.ex`).
`lib/harness/model_availability.ex` re-fetches the whole blocks map per predicate:

- `active_block/2` → `blocks()` → `SettingsStore.fetch(:model_blocks)` — one DB
  round-trip per call (`model_availability.ex:405-417`).
- `blocked_now?/2` calls it up to twice (agent-wide `:all` + pair) — 2 queries per check.
- `list_available/1` (`:113-120`) runs `blocked_now?` once per catalog entry → **1 + 2M
  queries for an M-model catalog**.
- `list_blocks/0` (`:316-318`) fetches `blocks()` once, then calls `active_block/2`
  inside the `Enum.filter` — which re-fetches the same row **once more per block entry**.

Amplifier: `SettingsLive.refresh/1` (`lib/harness/dashboard/settings_live.ex:326-342`)
runs `model_options/2` (→ `list_available`) for every agent-model + reviewer-model row
and `model_catalogs_state/1` (→ `catalog_universe`, itself 3–4 fetches per agent) for
all 6 agents — **on a 5-second `:meta_tick`** (`settings_live.ex:47,76-79`) and after
every event, per connected client. Order of 50–150 identical `harness_settings` point
reads every 5 s while the settings page is open.

**Fix:** load `blocks()` (and the three catalog maps) once per public entry point and
thread them through the private predicates; and/or give SettingsStore the same
app-env/`:persistent_term` write-through cache `Harness.Config` already uses — the
table is tiny and single-writer.

### H3 — HIGH · Synchronous CLI catalog probes inside a LiveView 5 s tick
`catalog_universe/1` → `probed_seed/1` → `cached_or_probe/1`: when the cached probe is
older than the 1 h TTL, `probe_and_cache/1` shells out **synchronously** —
`System.cmd("cursor-agent", ["--list-models"])`, `grok models`, `pi --list-models`,
`codex debug models`, `agy models` (`lib/harness/model_availability.ex:456-491,
634-667`) — serially inside `SettingsLive.refresh/1` on the LiveView process, driven
by the 5 s meta tick. One TTL-expiry tick blocks the settings LiveView for the summed
CLI startup latency (each probe is a full node/agent CLI boot; seconds each, five in a
row), and every connected client independently pays it (first-past-the-post caches for
the rest, but concurrent ticks race and probe redundantly).

**Fix:** never probe from the render path — serve stale-while-revalidate: return the
cached (even expired) catalog and kick an async `Task`/Oban job to re-probe and
broadcast; or move probing entirely to the existing cron surface.

### M1 — MEDIUM · Chat session list loads every message of every session
`lib/harness/chat/store/postgres.ex` `list/1`: `Repo.all` of all `chat_sessions` rows
including the full `messages` jsonb array (capped at 200 messages/session, but each
message can carry long content), then `decode_messages/1` walks every message just to
produce `label` (first user message) + `message_count`. Called by the chat sidebar.
**Fix:** `select: %{session_id: s.session_id, updated_at: s.updated_at,
count: fragment("jsonb_array_length(?)", s.messages), first: fragment("?->0", s.messages)}`.

### M2 — MEDIUM · Retention sweep runs on every run-record insert
`lib/harness/result_store/postgres.ex:75` — every successful `record_run/2` fires
`maybe_strip_old_transcript_blobs/1` → an `update_all` whose predicate
(`inserted_at < cutoff AND (agent_output IS NOT NULL OR reviewer_output IS NOT
NULL)`, `:297-306`) range-scans the `inserted_at` index over **all rows older than 30
days** (nearly the whole table) and heap-checks each for the not-null condition —
per settle, and re-run on every upsert of the same run (record_run fires at multiple
lifecycle points). **Fix:** a partial index
(`CREATE INDEX ... ON run_records (inserted_at) WHERE agent_output IS NOT NULL OR
reviewer_output IS NOT NULL` — stripped rows leave the index, making the sweep
O(rows-actually-strippable)); better, move retention to a daily Oban cron job instead
of the insert path.

### M3 — MEDIUM · KPI aggregates ship unbounded arrays out of Postgres
`aggregate_by_agent_query/0` (`postgres.ex:389, 421-427`) and
`aggregate_by_facet_query/0` (`:556, 585-590`) build
`array_agg(duration_ms ORDER BY duration_ms)` and
`array_agg(jsonb_build_object('review_skills', ?, 'review_ratings', ?))` over **every
row in history** — the result payload grows linearly with total runs (one jsonb pair
per run, per agent row), decoded into Elixir on each KPI refresh (see H1 for
frequency). The facet variant additionally wraps a full-table subquery. **Fix:** bound
to a time window (e.g. `where: r.inserted_at > ago(90, "day")`), or compute p50/p90
via `percentile_cont` and the rating means in SQL so only scalars cross the wire.

### L1 — LOW · Point lookups drag MB transcript blobs they don't need
`list_run_records(run_id: id)` retains `agent_output`/`reviewer_output`
unconditionally (`postgres.ex:231-239`), so `dispatch-verdict_detail`
(`lib/harness/dispatch.ex:1171`) loads both full transcripts to render verdict prose
only. `aggregate_ceremony_cost` (`result_store.ex:516-521`) loads **200 records with
transcripts** (potentially hundreds of MB) per MCP call by design. Fix: a
`columns:`/`:only` option on the point lookup; document/lower the ceremony default.

---

## 2. Missing DB indexes

- **LOW** — `run_records.adapter` and `run_records.task_fingerprint` are declared
  filterable (`@direct_filter_fields` / `:adapter` clause,
  `lib/harness/result_store/postgres.ex:769-786`) but unindexed
  (`priv/repo/migrations/20260712120000_add_run_records_lookup_indexes.exs` covers
  task_id/landed_sha/verdict/reviewer_adapter only). Sequential scan on those filters;
  currently rare call paths, so low.
- **LOW** — `chat_sessions` is listed `order_by: [desc: s.updated_at]`
  (`chat/store/postgres.ex`) with no `updated_at` index
  (`20260604100000_add_chat_sessions.exs`). Trivial at current volumes.
- **MEDIUM** — the retention-sweep partial index from M2 above (the one index gap with
  a per-write cost attached).

Otherwise index coverage matches the query paths (batch_id/agent/project_name/
inserted_at from the base migration; the 2026-07-12 lookup migration closes the
recovery/lander/aggregate predicates; the small stores are PK-only point tables).

---

## 3. Hot-path allocation (raw capture / parsing)

### M4 — MEDIUM · `LineBuffer.split/2` re-scans and re-copies the whole partial-line buffer per chunk; buffer is unbounded
`lib/harness/line_buffer.ex:48-55`: every chunk does
`combined = buffer <> IO.iodata_to_binary(chunk)` then `String.split(combined, "\n")`.
Two compounding costs, paid inside the `Harness.Run` gen_statem per port chunk
(`run/actions.ex:62-82` → parser state) and in every transcript parser:

1. The returned remainder is a **sub-binary** of `combined` (`List.last(many)`), so
   the next `buffer <> chunk` can never use the BEAM's in-place append optimization —
   a long line split across K chunks costs O(line²) total copying, and the sub-binary
   pins the full `combined` parent binary in memory until the next chunk.
2. `String.split` re-scans the already-scanned buffer prefix on every chunk — O(line²)
   scanning for the same pathological case.
3. **No cap**: an agent emitting one giant line (MB-scale JSON events are real for
   file-read tool results; Antigravity is plain text) grows the parser buffer without
   bound — the 200 KiB raw-buffer cap does not apply to parser state.

**Fix:** scan only the incoming chunk for `"\n"` (`:binary.matches(chunk, "\n")`),
keep the carried buffer as an iodata list joined only when a newline arrives,
`:binary.copy/1` the remainder to release the parent, and cap the partial-line buffer
(drop-with-marker beyond, say, 1 MB).

### L2 — LOW · `Transcript.append/3` steady-state copies ~200 KiB per chunk
`lib/harness/dashboard/transcript.ex:140-145, 208-217`: once the raw buffer hits the
200 KiB cap, every chunk appends (copying buffer+chunk, since the post-trim buffer is
a `binary_part/3` sub-binary) then re-trims. Bounded, but a chatty multi-hour run pays
a 200 KiB copy per chunk in the gen_statem. **Fix:** trim lazily — only when
`combined_bytes > 2 * @buffer_bytes` — amortizing to O(1)/byte; `:binary.copy/1` the
trimmed tail to drop the parent reference.

### L3 — LOW · Event-list append is O(cap) per chunk
`transcript.ex:172-206`: `events ++ delta` copies the whole ≤500-event list, and
`trim_events/1` walks it again with `length/1`, per chunk. Cheap in absolute terms but
in the per-chunk path; carry the count in state or hold the list reversed
(prepend + `Enum.take/2`) and reverse at read.

Clean: `Harness.TokenUsage.parse/2` is a single settle-time pass; mailbox growth on
the run gen_statem is bounded in practice by the port's chunking plus the
`MemoryGuard` sampler; per-chunk PubSub broadcasts are no-subscriber cheap.

---

## 4. GenServer bottlenecks

### L4 — LOW · Notification sinks run inline in the serialized landing job, no timeout
`lib/harness/notification.ex:53-55` delivers to each sink inline;
`CommandSink` execs the operator script via `System.cmd` with no timeout
(`notification/command_sink.ex:60`). A slow/hung notify script stalls the
`landing_<project>` queue (limit 1) — the merge train — for its full runtime. Wrap
delivery in a supervised `Task` with a bounded await (fire-and-forget is fine: sinks
are witness-only by contract).

Clean otherwise: `AgentRegistry` calls are map lookups (the one `System.find_executable`
probe is memoized); `Harness.Config` reads are app-env (no DB); `ModelAvailability`
holds no process (its problem is H2/H3, not serialization); chat sessions are
process-per-session with per-turn persistence.

---

## 5. LiveView

### M5 — MEDIUM · Roadmap shell-outs run unconditionally in mount and per-client on tick
`Harness.Dashboard.Live.mount/3` (`live.ex:107-125`) runs
`RoadmapSummary.for_projects/1` — one `rmap list --json` **shell-out per registered
project** (`roadmap_summary.ex:63-72`, concurrent but each a full process spawn) —
unconditionally, so it executes twice per page load (dead render + connected mount),
and again every 30 s per connected client (`:roadmap_tick`, `live.ex:305-317`).
`RoadmapLive` is worse: mount + 30 s tick also runs `drilldowns_for_projects/1`
(`roadmap_live.ex:160-175`) — `next_bundle` + `blocked` + `ready_waves` ≈ 3 more rmap
invocations per project per tick per client. Nothing is shared between clients.
**Fix:** a single cached refresher (GenServer/ETS, one tick for the node, PubSub to
clients) and `connected?/1`-gate (or `assign_async`) the mount read so the dead render
serves the cache.

### L5 — LOW · Full history re-stream every 30 s
`live.ex:561` — the roadmap tick calls `restream_history/1` →
`stream(:history, rows, reset: true)` re-sending all ≤200 history rows to the client
even when nothing landed. Diff the landed-set first and only re-stream on change.

Clean otherwise: active/history/chat use streams with dom-id keys and caps
(`@history_limit 200`, ops list 40, transcript events 500, raw pane 200 KiB with
UTF-8-safe truncation in OpsFeed); `compare_live` documents and enforces its bounded
per-lane assigns; `connected?/1` guards every PubSub subscribe and tick scheduler;
KpiLive's problem is the query side (H1), not socket payload.

---

## 6. Oban

Clean: queue-per-project with `concurrency_cap`-derived limits, landing queues fixed
at limit 1, worker uniqueness on `{project, task}` with `conflict?: true` in-flight
idempotency (`run/worker.ex:67-136`), Pruner at 24 h, cron queue registered
unconditionally but gated by the persisted master toggle. Audit/lander reads are
filtered + bounded (`audit.ex:409` limit, `:531` landed_sha-scoped with an explicit
anti-full-scan comment). No unbounded work found inside job `perform`s beyond the
store issues already covered in H1.

---

## Priority fix order

1. **H2/H3** — settings-store blocks cache + async catalog probes (biggest steady-state
   DB + latency win; touches every dispatch-time `available?` too).
2. **H1** — SQL-side stuck-cause/recovery rollups + settled-event debounce in KpiLive.
3. **M2** — retention partial index or cron-ify the sweep (per-settle write-path cost).
4. **M5** — shared roadmap-summary cache; connected?-gate the mounts.
5. **M4** — LineBuffer chunk-scan + remainder copy + cap (correctness-adjacent: unbounded).
6. Rest as convenient (M1, M3, L1-L5, index nits).

---

**Performance score: 66/100**
Justification: the run-execution core (Ports, gen_statem, Oban, git) is disciplined and
bounded, but the observability surfaces undermine it — uncached Postgres settings reads
multiplied by 5 s LiveView ticks (with synchronous CLI probes on the render path) and
full-table run-record loads re-run per settle event will degrade visibly as the run
ledger and project count grow, even for a single-operator node.
