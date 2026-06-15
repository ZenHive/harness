# Audit report for a6dd6e3 (landed range: Task 299 + KPI agents transpose)

**Range audited (already merged to development):**
- a6dd6e3 roadmap: task 299 -> done (shipped 10c3e57c62db)
- 10c3e57 harness: agent delivery — task 299 Run gen_statem crashed :undef on Harness.Run.reviewing/3 transcript_chunk path during node restart — reload-race or real gap? (run run-1781513424192-caa919da)
- 25e4c5d roadmap: task 299 -> in_progress
- 2e30911 roadmap(299): file Run :undef-on-reviewing transcript_chunk crash (reload-race hypothesis, dogfooding ccxt task 23)
- ca1e0ac dashboard(kpi): transpose agents ledger to metrics-rows × agents-columns, drop interactive sort

**What was reviewed:**
- The two source-bearing commits (10c3e57 and ca1e0ac) and their direct artifacts (docs/dogfooding-workflow.md addition, new test file `test/harness/run/code_reload_crash_test.exs`, updates to `test/harness/oban_dispatch_test.exs`, changes to `lib/harness/run.ex` + `run/result.ex` + `run/worker.ex`, and the KPI transpose across `lib/harness/dashboard/kpi_live.ex` + `tokens.ex` + its test).
- CHANGELOG.md (Unreleased) for gaps/staleness.
- The landed code for project conventions: @spec on every function (def + defp), one-line @doc where helpful, concise moduledocs, no bare TODO, useful regression + negative tests, no debug IO left in, no disabled checks, consistent naming and comments carrying (Task N) when tied to roadmap.
- Prior similar audits (e.g. e3cc95f, 163b30d, 6c37239) for report tone and depth.
- Cross-checks via grep for "sortable"/"sort" claims tied to the agents ledger page and for any leftover sort-th machinery or dead assigns after the transpose.

**Findings (3):**
1. **CHANGELOG gap for Task 299 resilience fix.** The Run crash-hardening delivery (classified `{:run_crashed, {:code_reload, ...}}`, crash record persistence, worker retention of in_progress + branch for `dispatch-rereview` recovery, terminate/3 + crash_settle path, dogfooding note) had no entry. This is material operator-visible behavior (recover paid work instead of silent reset) and matches the pattern of prior post-merge audits performing "changelog hygiene."
2. **Stale description of the agents ledger page (Task 298).** The Unreleased bullet for the split to `/harness/kpi/agents` still described "the wide sortable per-agent ledger" and "LiveView tests cover ... and sorting." The immediate follow-up landed in this range (ca1e0ac) transposed the presentation to a matrix (metrics down rows as sticky `th[scope="row"]`, agents across columns, `default_order` by run_count desc, removal of all interactive sort UI/handlers/tests/CSS, class `kpi-matrix`). The description and test-coverage claim were now inaccurate for the shipped surface.
3. **Minor duplicated constant (tech debt).** Task 299 added identical `@recoverable_code_reload_states [:reviewing, :recovering, :held]` in both `lib/harness/run.ex` (used by normalize/crash_settle) and `lib/harness/run/worker.ex` (used by recoverable_* guards + legacy bare-reason fallbacks for the Oban DOWN path). Small maintenance surface for future state changes. Not a bug; no behavior impact in the landed range.

No other hygiene issues found in the range:
- All new public and private functions carry `@spec` (including the terminate callback and the crash_* helpers) — matches the project's stricter-than-community rule.
- New/changed code has clear, non-obvious comments carrying (Task 299) where rationale is operational.
- The dedicated regression test exactly reproduces the reported crash signature (`{:undef, [{Harness.Run, :reviewing, [:info, {:transcript_chunk, ...}, ...]}]}`) and asserts the wrapped reason, ResultStore record, and subscriber notification. The paired negative test sends a real `transcript_chunk` while :reviewing and confirms survival (distinguishes "missing clause" from reload timing). Good coverage of the "real gap vs. reload-race" hypothesis.
- KPI transpose cleanly removed the sort surface (handle_event, toggle/sort helpers, sort_th component, default_sort assigns, .sort-th CSS) and added the matrix + sticky row-header CSS + deterministic `default_order`. No dead references or stale assigns remain in the module. Facet sub-tables already used busiest-first sort, now consistent with the dedicated ledger. Semantic HTML (scope) is an improvement.
- dogfooding-workflow.md addition is accurate, actionable, and limited to the operational hazard + recovery path.
- No IO/debug, no `@tag :skip`, no `# credo:disable`, no bare TODOs, no obvious naming drift (code_reload vs. reload is normal prose vs. file).
- No impact on the reviewer-rejection note for unrelated task 208 (coverage) — not in this range.

**What was fixed (2):**
- Updated the Task 298 Unreleased bullet for accuracy (transposed matrix, no sort, updated test coverage phrasing, parenthetical note on the follow-up commit).
- Added a concise "Fixed" entry for Task 299 at the head of the Fixed section (describes the crash classification, record + retention contract, recovery verb, tests, dogfooding note, and cross-refs the dupe observation).

The duplication (finding 3) was filed as a real follow-up task via the sanctioned mechanism rather than inlined as a refactor here (per "minimal viable diff" and "discovery filing" rules). See Task 300 on the canonical roadmap.

**Other notes:**
- The landed changes are mantra-clean: harness counts/mechanically reacts to the crash (persist record, retain branch, skip revert_to_pending); judgment and recovery remain with the operator/agent via `dispatch-rereview`.
- No re-verification or re-litigation of the agent-gate design was performed — only hygiene on the delivered artifacts.
- A clean range would still have received this report. The two changelog fixes were the only in-tree edits required.

**Filed discovery:**
- Task 300 (Consolidate @recoverable_code_reload_states (Run + Worker)) — the parallel list definitions.

Report written 2026-06-15 in the audit worktree for run-1781514174344-92260753. The commit `audit(a6dd6e3): ...` is the marker for the next audit.
