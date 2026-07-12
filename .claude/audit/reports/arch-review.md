# Harness Architecture Audit — `lib/harness/`

Scope: module structure, coupling/cohesion, supervision topology, boundary discipline.
Method: `mix xref graph` (cycles + stats), `mix reach.otp`, targeted reads.
Excluded by design (see CLAUDE.md — not defects): absence of scoring formulas/classifiers,
raw agent-output passthrough, one-run-one-gen_statem + Oban wrapping.

## Findings, ranked by severity

### 1. [HIGH] One giant strongly-connected component — 71 of ~237 modules (≈30%) form a single cycle

`mix xref graph --format cycles` reports one cycle of length 71 spanning nearly every
subsystem: `dispatch.ex`, `run.ex` + all `run/states/*` + `run/actions/*`, `lander.ex` +
`lander/*`, `roadmap.ex`, `manifest.ex`, `oban.ex`, the entire `dashboard/*` tree (endpoint,
router, every LiveView, MCP plug/server), `chat/*`, `audit.ex`, `batch.ex`,
`capability_score.ex`, `cron/*`, `result_store.ex`, `agents.ex`, `config.ex`, `describe.ex`,
`code_search.ex`, `dependency_bump.ex`, `dep_freshness.ex`, `routing.ex`, `status_view.ex`,
`suite_health.ex`, `tooling_baseline/dispatch.ex`.

This means the codebase has **no enforced layering**: run-lifecycle internals, the dashboard
UI, the MCP surface, and cron pollers are all mutually reachable. You cannot compile or
reason about any one of these 71 modules independently of the rest. A chunk of the cycle
traces to `Harness.Manifest`'s `@driver_surface` list (a curated module-atom list consumed by
`descripex` to build the MCP/chat tool manifest) creating export/compile edges back into
`Dispatch`, `Run`, `Roadmap`, etc., while those same modules' docs/specs reference back
through `Describe`/`Chat.Tools`/dashboard LiveViews that also read `Manifest`. The manifest
pattern is a legitimate "curated facade" concept, but nothing stops the reverse edges (e.g.
`dashboard/roadmap_live.ex` depending on `run/actions/worktree.ex`-adjacent internals) from
folding the whole app into one component instead of `core → manifest → {chat, mcp, dashboard}`
one-way layering.

**Fix direction:** the driver-surface modules (`Run`, `Roadmap`, `Dispatch`, `ResultStore`,
etc.) should never depend on `Manifest`, `Chat.*`, or `Dashboard.*` — only the reverse. Audit
which edges in the 71-cycle are genuinely bidirectional business logic vs. accidental
doc/alias references pulling a cold-path module into the warm-path's compile graph.

### 2. [HIGH] `Harness.Dispatch` is a 1821-line god module mixing 5+ distinct concern groups

`lib/harness/dispatch.ex` (1821 lines, 15 outgoing xref edges — 2nd-highest in the project)
is the MCP/driver-surface facade, but it does not stay a thin facade. It houses, in one
module:

- run dispatch + await (`task/4`, `await/3`, `await_runs/2`, `await_result/2`)
- lifecycle control (`cancel/1`, `hold/2`, `steer/2`, `resume/1`, `resume_failed/2`,
  `rereview/1`, `reland/1`)
- project administration (`register_project/6`)
- cron/manual-approval admin (`pending/1`, `approve/1`)
- cross-adapter benchmarking (`compare/3..5`, `verdict_detail/1`)
- capability routing (`recommend/2`, `assess_facets/1`)
- adapter/model resolution internals (`ensure_model_available/4`, `effective_model/2`,
  `recommended_adapter_for_item/3`)

Each group is a different abstraction level and a different audience (an orchestrator
dispatching work vs. an operator approving parked decisions vs. a scout doing A/B routing).
A single module this wide has no cohesive single responsibility — it reads as "everything the
MCP surface exposes," which is a real organizing principle for an *index*, but the
implementation bodies belong in per-concern modules that `Dispatch` delegates to.

**Fix direction:** split into `Dispatch.Lifecycle` (cancel/hold/steer/resume/rereview/reland),
`Dispatch.Admin` (register_project/pending/approve), `Dispatch.Compare`
(compare/verdict_detail/recommend/assess_facets), keeping `Dispatch` itself as a thin
re-export facade for the `descripex api()` annotations if the MCP tool-naming convention
requires one flat namespace.

### 2b. [MEDIUM] Mixed abstraction levels inside `Dispatch`

Within the same module, `task/4` operates at "start a run" granularity while
`poll_until_settled/3`, `settled_await_summary/1`, `snapshot_await_summary/1`,
`vanished_summary/1` are low-level polling/formatting helpers for `await/3`'s human-readable
output. The formatting helpers (`record_await_summary`, `record_review_summary`,
`resume_reason_text`, `prior_attempt_section`) are presentation logic (turning a `LogRecord`
into prose) sitting next to orchestration control flow — a different concern from "dispatch a
run," and a candidate for extraction regardless of the god-module split above.

### 3. [MEDIUM] `Harness.AgentRegistry` ↔ `Harness.ModelAvailability` — tight 2-module cycle

`agent_registry.ex` calls `ModelAvailability.capture_structured_failure/3`;
`model_availability.ex` calls `AgentRegistry.agent_for_module/1` and `AgentRegistry.agents/0`.
Both are legitimately related domains (which agent can run this / which models are available
for it), but the mutual dependency means neither module can be understood, tested, or
reasoned about without the other, and neither can be the "lower" layer. If the coupling is
intentional, it should be documented as such; otherwise pull the shared surface (agent↔model
capability lookups) into a third module both depend on one-way.

### 4. [LOW] Dead GenServer replies in `Harness.Cron.PendingDispatch`

`mix reach.otp` flags two discarded `GenServer.call` replies in the private `enqueue/1`
helper (`lib/harness/cron/pending_dispatch.ex:174` and `:178`):

```elixir
GenServer.call(__MODULE__, {:complete, record.id})   # reply discarded
...
GenServer.call(__MODULE__, {:repark, record})         # reply discarded
```

Both always reply `:ok`, so this is not a live bug today, but the pattern silently swallows
the outcome of the completion/repark write — a future change that makes either handler
capable of failing (e.g. a validation branch) would have its error dropped on the floor with
no signal at the call site. Low severity, but a one-line `:ok = GenServer.call(...)` (already
partially done for `:complete`'s sibling pattern elsewhere in the module) or explicit match
closes the gap cheaply.

### 5. [LOW] Repeated behaviour↔impl cycle pattern (4 instances) — idiomatic but worth naming

`SettingsStore` ↔ `SettingsStore.Postgres`, `Chat.Store` ↔ `Chat.Store.{Memory,Postgres}`,
`SuiteHealthStore` ↔ `SuiteHealthStore.{Memory,Postgres}`, `DepFreshnessStore` ↔
`DepFreshnessStore.{Memory,Postgres}` each form a 2–3-node xref cycle: the behaviour module
declares `@callback`s and its impls declare `@behaviour Harness.XStore`, while the behaviour
module also references the impl module name (as a default `configured/0` target or in
moduledoc). This is the standard Elixir behaviour+default-impl pattern, not a design flaw —
noted only because it inflates the raw cycle count (4 of the 8 reported cycles are this same
shape) and is worth distinguishing from the real coupling issues above (#1, #3) when triaging
`mix xref graph --format cycles` output going forward.

### 6. [LOW] `dashboard/transcript/parser.ex` ↔ per-agent parser modules — cycle of 7

`parser.ex` and its five per-agent parsers (`claude.ex`, `codex.ex`, `cursor.ex`, `grok.ex`,
`pi.ex`, plus `passthrough.ex`) form a 7-node cycle: the dispatcher module calls out to each
per-agent parser, and each per-agent parser presumably aliases the dispatcher for shared
types/behaviour. Same shape as #5 — a dispatch-table pattern, not obviously a defect, but
confirm the per-agent modules don't need anything from `parser.ex` beyond a shared struct/type
that could live in a separate `Parser.Types` module to break the cycle if it ever matters for
compile-time isolation.

## Clean areas (one line each, not re-litigated)

- `Harness.Project` — 133-line pure struct + 3 tiny predicate helpers; its 48 incoming edges
  are expected fan-in for the app's central data type (same shape as an Ecto schema), not a
  god-module symptom.
- Supervision tree in `application.ex` is legible and well-commented (explicit boot ordering
  rationale for Repo → MigrationGuard → Config → registries → PubSub → Run.Supervisor →
  Oban → dashboard/MCP); all long-lived GenServers/gen_statems found by `mix reach.otp`
  (`AgentRegistry`, `CodeSearch.Server`, `Cron.PendingDispatch`, `Worktree.Reaper`,
  `ProjectRegistry`, `Chat.Supervisor`/`Chat.Session`, `Run`/`Run.Supervisor`, `Oban`,
  `Dashboard.MCPPlug`) are supervised, none orphaned.
- Hot/warm/cold path split is respected structurally: raw Port capture stays allocation-light
  in the adapter layer, `Run`/`Batch` lifecycle is warm-path OTP state, dashboard/MCP/Oban Web
  are cold-path on a separate Bandit endpoint — no violations found crossing these boundaries.
- Judgment-vs-mechanics discipline (the project's core mandate) holds up under this pass — no
  scoring formula, keyword classifier, or normalization layer was found masquerading as
  mechanical code; `.harness/*.json` verdict reads stay mechanical as designed.
