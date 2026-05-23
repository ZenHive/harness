---
sha: 4678fb8a769ee50caff8a36558dde3277fac3356
short_sha: 4678fb8
audited_at: 2026-05-24
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: feat: structured run logging + pluggable result store (Task 19)

**Original commit:** 4678fb8 — `feat: structured run logging + pluggable result store (Task 19)`
**Author:** E.FU (Codex-delivered; hand-integrated onto `development` post-Round-3a — see Task 41 for the Codex worktree-isolation regression that drove the integration path)
**Files touched:** 11 (`config/config.exs`, `lib/harness/batch.ex`, `lib/harness/batch/result.ex`, `lib/harness/result_store.ex` NEW, `lib/harness/result_store/file.ex` NEW, `lib/harness/run.ex`, `lib/harness/run/log_record.ex` NEW, `lib/harness/run/result.ex`, `lib/harness/worktree.ex`, `test/harness/batch_test.exs`, `test/harness/run_test.exs`)
**LOC:** +701 / −30 (largest commit in batch)

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 5 | 6 doc-gap | CHANGELOG.md | `[Unreleased]` missing Task 19 entries (`ResultStore`, `ResultStore.File`, `LogRecord`, `:result_store` config, `BatchResult.batch_id`, new `RunResult` fields) | applied: added five entries covering the whole Task 19 surface (Claude + Codex agreed) |
| 2 | 6 | discuss-design → dialogue-resolved | lib/harness/batch.ex:103 | `Batch.run/4` returns `{:ok, result}` even when `ResultStore.save_batch/2` fails; persistence errors only logged | applied: documented best-effort contract in `Harness.ResultStore` moduledoc; behavior unchanged (codex finding) |
| 3 | 4 | 1 bug | lib/harness/result_store/file.ex collect_records | `Enum.reduce_while` lambda has no clause for `{:ok, non-LogRecord}` — a stray term file would crash `list_run_records/2` with `FunctionClauseError` | applied: added `{:ok, _other}, ...` skip clause (codex finding, verified) |
| 4 | 4 | 1 bug | lib/harness/result_store/file.ex load_batch | Returns `{:ok, term}` for any decodable term — no `%BatchResult{}` struct check, callers could receive a `LogRecord` or arbitrary term | applied: added struct-shaped match + `{:invalid_term_file, path}` on type mismatch (codex finding, verified) |
| 5 | 3 | 1 spec | lib/harness/result_store.ex:100 | `@spec dispatch(store(), atom(), [term()])` accepts `nil \| false` but the `dispatch/3` clauses only match `{module, opts}` and `module` | applied: tightened spec to `module() \| {module(), keyword()}` (Claude finding) |

## Auto-applied fixes

- `CHANGELOG.md` — added entries for `Harness.StatusView` + `mix harness.status` (Task 18), `Harness.ResultStore` + `Harness.ResultStore.File` (Task 19), `Harness.Run.LogRecord` (Task 19), `Harness.Batch.Result.batch_id` field (Task 19), and `Harness.Run.Result.first_attempt_failed_check_count` / `agent_diff_size` fields (Task 19).
- `lib/harness/result_store.ex` — added "Best-effort persistence" section to the moduledoc spelling out the log-and-continue contract (`record_run`/`save_batch` errors are logged via `Logger.warning/1`, never crash a run or flip `Batch.run/4`'s `{:ok, _}` to `{:error, _}`).
- `lib/harness/result_store.ex:100` — tightened `@spec dispatch/3` from `store()` to `module() \| {module(), keyword()}` so the spec matches the actual function-clause shapes.
- `lib/harness/result_store/file.ex load_batch/2` — added explicit `%BatchResult{}` shape check; returns `{:error, {:invalid_term_file, path}}` for a decodable-but-wrong-type term file.
- `lib/harness/result_store/file.ex collect_records/2` — added `{:ok, _other}` skip clause so a non-`LogRecord` `.term` file in `runs/` is skipped (with no spurious crash) instead of triggering `FunctionClauseError`.

## Discuss-tier resolutions

- **dialogue-resolved (#2 above):** Both reasoners agreed best-effort persistence is the intended contract (record_run can be disabled via `false`/`nil`; per-run records still emit independently; `Logger.warning/1` is the surface), but the public contract was implicit. Claude+Codex converged on "document, don't change behavior". Applied via moduledoc edit on `Harness.ResultStore`.

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: 1 (CHANGELOG gap — Claude + Codex agreed)
Codex-only findings (verified): 2 (best-effort persistence contract), 3 (collect_records FunctionClauseError on non-LogRecord), 4 (load_batch type safety)
Codex-only findings (discarded as over-flag): —
Codex notes: `mix dialyzer.json`, `mix credo`, `mix test.json` outside of offline scope were unable to run in Codex's sandbox (Mix PubSub `:eperm`); offline test suite 279/279 passed in its session. Codex correctly flagged that the `ResultStore` callbacks Codex was asked to verify (`init/1`, `start/2`, `persist/3`, `finalize/2`) do not exist — confirming the actual callbacks are `record_run/2`, `save_batch/2`, `load_batch/2`, `list_run_records/2`.

## Acceptance-criteria cross-reference

No PR / Linear context (solo-dev offline repo). Acceptance criteria are recorded in `roadmap/tasks.toml#19`:
- ✅ Each run emits a structured, queryable log record (`Harness.Run.LogRecord` + `Harness.Run.settle/2` persist path)
- ✅ The record carries first-attempt failed-check count, agent diff size, verdict, duration, repair attempts (`Harness.Run.LogRecord.t/0`)
- ✅ The record is reloadable after the process exits (`ResultStore.list_run_records/2`, file-backed persistence)
- ✅ Failure cause reconstructable from the record (`failure_cause: %{reason: ..., failed_checks: [...]}`)
- ✅ Store is pluggable, file-backed by default (`@behaviour Harness.ResultStore` + `ResultStore.File`)

All five criteria met by the committed code; no rmap follow-ups filed for unmet criteria.
