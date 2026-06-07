# audit(ccd4e41) — Tasks 234/238/239 range hygiene pass

**Range audited (already landed on development):**
- ccd4e41 `roadmap: task 239 -> done (shipped 129d6d83724b)`
- 129d6d8 `harness: agent delivery — task 239 Implementer-phase idle watchdog — a wedged :running agent holds a queue slot up to the 90-min lifetime cap (run run-1780832746660-843184ed)`
- ea4c040 `roadmap: task 238 -> done (shipped 485fdeff428d)`
- 485fdef `harness: agent delivery — task 238 Fix MCP dispatch-hold boolean-arg coercion + document hold→steer→resume recovery in harness-driver SKILL (run run-1780832744894-b5b38535)`
- ae5b1cd `roadmap: task 234 -> done (shipped 531b3ab9cdef)`
- 531b3ab `harness: agent delivery — task 234 MEASURE the fragmentation / ceremony tax — quantify per-task dispatch overhead from the per-run token facts already captured (run run-1780832742494-db9aae0e)`
- 498a185 `roadmap: file task 240 — pinned model never reaches Invocation (--model dropped)`
- (plus the three prior roadmap state markers for the tasks and the cursor multi-model prep commit 6a58ea5)

Prior audit marker: b67180e (Task 216 range).

## What was delivered

Three small, focused mechanical additions, each gated by a cross-family reviewer:

- **Task 234 (ceremony tax).** New `AgentKPI.aggregate_ceremony_cost/1` + `ResultStore.aggregate_ceremony_cost/2` + `ceremony_tokens/1` (public). For every `:approve` + `:done` record it emits a per-run `{task_id, run_id, total, tokens: %{implementer, reviewer, audit: 0}}` entry plus median/p90 distributions over the components. Reviewer spend is parsed from `reviewer_output` via `TokenUsage` (the store wrapper forces `include_transcripts: true`); audit is explicitly 0 until capture lands. Pure rollup over facts already on `LogRecord`; no magic weights, no batching recommendation. SKILL.md and the driver surface document the new `result_store-aggregate_ceremony_cost` tool.
- **Task 238 (dispatch-hold coercion + recovery doc).** `Harness.Chat.Tools.dispatch/3` now runs a `coerce_args` pass before schema validation for any param whose schema or default marks it boolean. Covers the common MCP/JSON caller shapes (`"true"`, `"false"`, `{"value": true}`). The `interrupt` param declaration on `dispatch-hold` (in `Dispatch`) gained `schema: boolean()`. Added coercion tests in both the MCP server test and the dispatch schema test. Driver skill gained the canonical "Live recovery loop — hold → steer → resume" paragraph with the force-handoff pattern for a grinding implementer.
- **Task 239 (implementer idle watchdog).** `:running` now arms its own gen_statem `state_timeout` idle watchdog (sibling to the Task 199 reviewer one). Floor is 10 min (`@implementer_idle_floor`) so a long silent compile/test/dialyzer does not evict the attempt; explicit `:implementer_idle_timeout` run opt, higher values, and `:infinity` win; `nil`/lower values are raised. Transcript chunks re-arm it once the agent handle is captured. On fire the run settles `{:timed_out, :idle}` outcome and the reviewer still gates. Extracted `settle_implementer_outcome/2` (the old committing-path logic) to keep the handler small. New unit tests for the floor function + watchdog arm/re-arm + settle-through-watchdog path. `rearm_running_idle/3` mirrors the reviewer pattern.

Files with meaningful churn (roadmap markers excluded): `run.ex` + `run_test.exs` (239), `chat/tools.ex` + `dispatch.ex` + `mcp_server_test.exs` + `dispatch_test.exs` + SKILL.md (238), `agent_kpi.ex` + `result_store.ex` + backends + `agent_kpi_test.exs` + SKILL.md (234). Plus the two doc surfaces touched by this audit (CHANGELOG, orchestrator-surface-inventory.md).

## Hygiene review (what matters)

- **No dead code, no leftover debug.** The three deliveries are additive and small. Extracted helper `settle_implementer_outcome/2`, new coerce trio, and the ceremony rollup functions are tight, single-purpose, and free of IO/pry/dbg. Grep for bare TODO/FIXME/IO.inspect across lib/harness in the range turns up only the legitimate `IO.iodata_to_binary` sites in transcript plumbing (pre-existing, unrelated).
- **Conventions.** All new public functions carry `@spec` + `@doc`. All new `defp` carry `@spec` on the primary head (fallback clauses follow the project "spec the head" pattern). New types (`ceremony_*`) are documented. The one `@doc false` public (`implementer_idle_timeout/1`) is explicitly called out as test-only surface, matching the reviewer idle precedent. Coerce fallbacks in `tools.ex` are consistent with the rest of that module.
- **Naming / structure.** No drift. `ceremony_tokens/1` is the natural dual of the internal breakdown; the result shape (`ceremony_cost`, `ceremony_entry`, `ceremony_breakdown`, `ceremony_distribution`) is descriptive and matches the existing `duration_summary` style. The watchdog re-arm helper is named `rearm_running_idle` to sit beside `rearm_reviewing_idle`. Boolean coercion is isolated to `coerce_*` and only applied for declared boolean params — minimal and targeted.
- **Tests.** Real coverage for the new behaviors: floor arithmetic (nil/lower/above/infinity), watchdog trip + re-arm via transcript chunks, coercion over the five common JSON shapes, ceremony sum + distribution + empty + missing-reviewer-output cases. No trivial "assert true" tests.
- **CHANGELOG gap (found + fixed).** None of the three agent-delivery commits (531b3ab, 485fdef, 129d6d8) or their done markers touched `CHANGELOG.md`. The prior audit in this lineage (d1d2171 for b67180e) established the forward-fix pattern and supplied the missing entry for its range. Added three proportionate entries under Unreleased/Added (ceremony measurement, hold coercion + recovery contract, implementer idle watchdog) with the same density and "mechanical facts only" tone as the surrounding entries.
- **Stale / incomplete documentation (found + fixed).** `docs/orchestrator-surface-inventory.md` (the canonical Task 184 inventory) listed only `result_store-aggregate_by_agent` under AgentKPI rollups in both the read/observe table and the desired-set summary. The new `result_store-aggregate_ceremony_cost` surface (Task 234) was documented in the driver skill and exposed via `api()`, but invisible in the inventory. Added the row in the read table and updated the desired row to name both rollups (parallel to how the task-216 audit updated the same doc for the scout surface). No other inventory drift for the 238/239 changes (hold/steer/resume were already called out; the idle watchdog is an internal Run detail, not a new orchestrator surface).
- **CLAUDE.md / other docs.** The one CLAUDE.md change in the broader range (6a58ea5, "cursor is a multi-model front-end") is a preparatory commit for task 240 context, accurate, and unrelated to the three deliveries under audit. `agent-gate-workflow.md` and other design docs had no material staleness for these mechanical additions.
- **Reviewer rejections.** None recorded for this project in the supplied context. The three deliveries were each reviewed by a cross-family agent; the landed diffs (including the coercion tests and the watchdog settle-through-reviewer test) are sound.

**No further code changes were required.** The two documentation fixes (CHANGELOG + inventory) plus this report are the complete set. The range is otherwise clean — exactly the class of post-delivery doc debt an audit is for.

## Outcome

The landed range implements the three tasks correctly per the agent-gate rules: implementers delivered the mechanical substrate (watchdog, coercion, pure ceremony rollup), reviewers gated, and all judgment (what the ceremony numbers *mean* for batching, whether a hold was the right operator move) stays with orchestrators and reviewers, never in harness arithmetic. The only hygiene debt was the expected missing changelog entries and the one canonical surface inventory that had not been updated when the new KPI surface was added — both fixed forward.

**Commit:** `audit(ccd4e41): changelog + orchestrator inventory for ceremony cost + idle watchdog + hold coercion (range otherwise clean)`

(The `.harness/audit.json` machine summary is written alongside but not committed, per the audit contract.)
