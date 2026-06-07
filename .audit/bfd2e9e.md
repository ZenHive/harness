# Audit Report: bfd2e9e (Task 237 Cron manual-approval dispatch mode)

**Range audited (already landed on development):**
- `bfd2e9e` — roadmap: task 237 -> done (shipped 02009a56c2f7)
- `02009a5` — review: harden manual cron approval dedup
- `fcd4514` — harness: agent delivery — task 237 Cron manual-approval dispatch mode — park autonomous dispatch for operator approval before enqueue

**Scope of review (hygiene only; merge is settled):**
- Dead code, debug output, broken conventions, inconsistent naming, missing/stale docs, CHANGELOG coverage, test quality for the new surface.
- Cross-checked the two new JSON/MCP tools (`dispatch-pending`, `dispatch-approve`) and the `Harness.Cron.PendingDispatch` + dispatch-mode additions in `Settings` / `RoadmapPoller` / `Oban`.
- Verified the hardening commit (02009a5) addressed the claim/park race that the initial delivery left (status tuple `{:parked|:claimed, record}`, explicit `{:complete, id}` after successful enqueue, pre-park `unfinished_run_job?` guard in `park_for_approval` mirroring the Oban unique path).
- No reviewer rejections recorded for this project (per the provided feedback loop); nothing to note as a potential false rejection.

**Findings:**
- Core delivery is sound and matches the architecture (mechanical gate only; orchestrator AI still chooses the work; idempotency + atomic claim preserved; soft in-memory state contract consistent with `AgentRegistry`).
- CHANGELOG entry present and accurate under Unreleased → Added.
- Tests added for the hardening (claimed-while-enqueue race, MCP surface exposure, interactive dispatch ungated, `unfinished_run_job?` detection).
- No dead code, no `IO.inspect`/debug, no bare `TODO`, no disabled checks.
- One convention violation: the error fallback clause of `set_dispatch_mode/3` in `lib/harness/cron/settings.ex` (introduced in the range) lacked a preceding `@spec` while the valid-path clause had one. Per project rule ("@spec on every function — `def` AND `defp`"), added the spec to the fallback clause.
- Stale docs: the new `api(:pending, ...)` / `api(:approve, ...)` surfaces (and the manual cron approval flow) were absent from the canonical driver contract and surface inventory, even though `api()` annotations make them first-class on the MCP/chat layer. Updated:
  - `skills/harness-driver/SKILL.md` (Primary Surface table + "When to use which" + exposed-tools list)
  - `docs/orchestrator-surface-inventory.md` (Write / control table)
- The `bfd2e9e` commit itself only touched `roadmap/tasks.toml` + `roadmap/data.json` (the expected "done" marker). Per operational rules, the roadmap was not edited by the audit.

**Fixes applied (own edits, one commit):**
- Added `@spec` to the `set_dispatch_mode` error clause (settings.ex).
- Added concise entries for `dispatch-pending` / `dispatch-approve` in the two driver/orchestrator docs.

**Outcome:** Clean range after the two minimal forward fixes. No behavior changes, no scope expansion. The landed work + hardening is hygienic and ready for the next audit marker.

**Machine summary (see .harness/audit.json):**
findings: 2 (1 spec convention, 1 doc staleness); fixed: 2; report written.
