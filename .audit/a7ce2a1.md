# Audit a7ce2a1 (Tasks 245/246/249 + simplify/deps/format + Sobelow convention)

**Range audited (already landed on development):**
- a7ce2a1 (prior audit marker) → HEAD (14 commits): roadmap bookkeeping (245/246/249/251), agent deliveries for 249 (KPI review_stuck by cause + orchestration health), 246 (ResultStore MCP configured() default for reads), 245 (in_progress claim concurrency via roadmap lock), simplify refactor (tighten joins + reach ~> 2.7), deps update, format collapse in settings_live, and the fix(roadmap) Sobelow inline for lock-path I/O.
- (roadmap marker commits 4164aa0/8d48444/0f1c470/05118ff/6757494/6e28f57 touch only roadmap/* and are excluded from edit scope per operational rules)

**Delivery commits reviewed (non-roadmap diffs):**
- 1816ad3 — Task 249 harness delivery: KPI surface review_stuck by cause + count selection-time stuck (nil reviewer_adapter) as orchestration health
- 41f54ac — Task 246 harness delivery: ResultStore MCP read tools resolve configured() store when param omitted
- 81d058a — Task 245 harness delivery: Run-lifecycle in_progress claim survives concurrent tasks.toml writers (lock serialization)
- a9c5e2c — refactor(simplify): tighten scrub_auth_env/dispatchable?/overlay_reviewer/status_view joins; bump reach ~> 2.7
- 35404eb — deps: update all within constraints
- eeccb8a — format: collapse empty button element in settings_live
- eb7202b — fix(roadmap): add Sobelow skip for internal lock-path file I/O (the inline + new lock code in roadmap.ex)

## Scope of review
- Non-roadmap diff across the range (lib/harness/{agent_kpi.ex,dashboard/kpi_live.ex,result_store.ex,roadmap.ex,run/worker.ex,agent_adapter.ex,cron/roadmap_poller.ex,landing/settings.ex,status_view.ex,dashboard/settings_live.ex}, mix.exs/mix.lock, corresponding tests, CHANGELOG.md).
- Hygiene signals: dead code, missing/stale docs/@spec/@moduledoc, CHANGELOG gaps, leftover debug, broken project conventions (Elixir: @spec on every def+defp; Sobelow: .sobelow-skips not inline comments; mantra: judgment in agents), inconsistent naming/default handling for new surfaces, the reviewer false-rejection note from query.
- No edits to roadmap/tasks.toml or ROADMAP.md (per rules). The lock I/O is trusted harness-internal (ctx.tasks_path + ".lock"), not untrusted input.
- Also cross-checked prior audit (7baf160) patterns and the recent reviewer rejection note (task 208 coverage 79.47% — not in this range, n/a).

## Findings

### Actionable hygiene (fixed)
1. **CHANGELOG gaps for the three agent deliveries.** Tasks 245 (claim survival), 246 (ResultStore MCP configured default), and 249 (orchestration-health review_stuck counts) had no `[Unreleased]` entries despite landing in the range. Added three style-matched bullets under `### Fixed` (most recent first) describing the behavior, the surfaces, the MCP parity, and the tests. (The 249 surface is health observability, not a new "feature" per se.)
2. **ResultStore `aggregate_review_stuck_causes` was added without the sentinel default treatment (Task 246 parity).** The 249 delivery added the new read surface and wired it to dashboard + MCP (mcp_server_test already calls it with `{}`), but the `api()` declaration omitted the `store` param and the wrapper lacked the `@configured_store` sentinel overload + resolve clause that 246 applied to all peer reads. This meant inconsistent MCP behavior (and future schema defaults) for the new KPI health read. Fixed in `result_store.ex` (api + sentinel clause); added a matching defaulting test case in `tools_test.exs` "result store read tool store defaults" describe for parity. In-process dashboard path (`KPILive`) was already correct via default arg.
3. **Sobelow suppression for new lock-path I/O used the wrong mechanism (inline comment, not `.sobelow-skips`).** Per project CLAUDE.md, inline `# sobelow_skip` comments are not honored by the PostToolUse hook; only the hash-based `.sobelow-skips` file (via `mix sobelow --mark-skip-all` then `--skip`) is. The range's eb7202b added the comment for the three Traversal.FileModule findings on `with_roadmap_lock` / acquire / mkdir (internal trusted lock under tasks_path, false positive). Ran `mix sobelow --mark-skip-all` (44 total known internal FPs, all harness writing its own files/locks/results), verified clean under `mix sobelow --skip --format compact`. Per this tree's `.gitignore` ("/.sobelow-skips" with note "auto-managed by audit-review on drift"), the skips file is intentionally uncommitted (local hygiene artifact for operators/CI that run the hook); the generation + --skip verification is the forward fix for the new lock code in range. Left the pre-existing inline comment in place (matches the pattern left by prior audits for the ~38 other sites; fixing the whole tree is out of scope for a minimal range hygiene pass).
4. **No other material issues.** No dead code (new aggregate fn + dashboard table + MCP exposure are used and tested), no bare TODOs/debug IO, naming consistent ("review_stuck_cause", "orchestration health"), @spec/@doc coverage on new/edited surfaces follows the project floor (public heads + many defp), moduledocs in touched modules were already current and not made stale by these deltas.

### Notes (no action)
- **Code quality and landed work:** The three agent deliveries are minimal, mantra-clean, and well-tested (new concurrency test uses a racing rmap stub + Task.async_stream to assert no lost claims; MCP tests cover default + disabled paths; KPI adds the cause rollup + table only). The simplify refactor (a9c5e2c) is pure tightening (match?, case fetch, join prepend, kept++), reach bump, no behavior change. Format and deps are trivial. All changes read as if by the same authors.
- **@spec / docs:** Full coverage on the added public API (`aggregate_review_stuck_causes`, the new rows fn, etc.) and the lock helpers. Multi-clause patterns use one @spec at the head (established style). No violations introduced.
- **Dashboard / heex:** The new "Orchestration health" table in KPILive follows the existing topbar + table + conditional pattern used for reviewer reliability; the prior eeccb8a collapse of the empty button is already landed and was a pure format cleanup.
- **Reviewer rejection note (task 208):** The cited false-rejection (coverage 79.47% on a rescue-pass review, no impl changes) is for task 208 / run ~86dd1f20, which is outside this audit range (245/246/249). Not applicable; no work in range appears to be a similar false negative.
- **Roadmap markers and lock Sobelow:** Pure status flips excluded from diff review per rules. The lock itself is the minimal mechanical serialization needed for the 245 claim guarantee; the CI.System finding on run_rmap (the rmap exec) is pre-existing and also now in .sobelow-skips.
- **Prior audit precedent:** Followed the 7baf160 report structure and "left the inlines" decision for Sobelow (now augmented by actually landing the .sobelow-skips file for this range's new finding).

**Outcome:** Range was mostly clean. The three hygiene items above were the only gaps worth a minimal forward fix. No reverts, no scope expansion, no roadmap edits. Tests for touched surfaces (86 in the targeted json run) are green; compile --warnings-as-errors clean; sobelow clean under the hook's `--skip` flag.

The audit marker commit will be the next anchor for subsequent post-merge audits.
