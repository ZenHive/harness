# Audit — 2cfdd20 (range ac07911..HEAD)

**Verdict: clean.** No hygiene fixes applied.

## Range reviewed

| Commit | Subject |
|---|---|
| 92831d5 | roadmap: task 318 -> in_progress |
| 7ed520b | harness: agent delivery — task 318 Post-merge cold-build witness |
| 0e5c712 | review: document cold-build witness in Audit moduledoc and harness-driver skill |
| 2cfdd20 | roadmap: task 318 -> done (shipped 0e5c712c6500) |

All four commits implement **Task 318 — post-merge cold-build witness**: the audit
worktree is no longer warmed, the audit AI runs the project check in the cold tree
and reports a `cold_check` fact in `.harness/audit.json`, harness persists that fact
on the landed run record, and a reported red files a blocked follow-up rmap task +
notification (never a revert/unmerge/gate).

## What I checked

- **`lib/harness/audit.ex`** — the core change. `Worktree.warm/2` correctly removed
  from the audit path; `audit_report/1` (was `log_audit_report/1`) now returns the
  decoded map so `witness_cold_check/4` can persist it. THE MANTRA respected:
  `cold_check_failed?/1` *reads* the agent-written `passed` boolean — harness never
  runs the build or reads an exit code. The auto-filed blocked-task path is mechanical
  (fixed phase/bundle/scores constants), not a judgment about the run.
- **Shell-out safety** — `run_rmap/2` uses `System.cmd` with an argv list (no shell);
  `run_rmap_with_input/2` passes the TOML fragment via the `HARNESS_RMAP_FRAGMENT`
  env var rather than interpolating it into the shell string, and the tasks path is
  `$1`, not interpolated. Both carry correct `sobelow_skip` annotations. The
  `--tasks-path` flag is confirmed valid against the installed `rmap` CLI.
- **Persistence plumbing** — migration `20260620120000_add_cold_check_to_run_records`,
  `RunRecord` schema field + cast, `LogRecord` type/default/`@moduledoc`, and the
  Postgres encode/decode + upsert `COALESCE(NULLIF(..., '{}'), prior)` merge are all
  consistent. `decode_optional_freeform_block/1` correctly keeps `nil` distinct from
  `%{}` (the field is `nil` until an audit writes it).
- **Tests** — `test/harness/audit_test.exs` adds a red-path test (cold tree ⇒ red
  `cold_check` ⇒ blocked task filed via a fake `rmap`, notification fired, merge
  untouched, record persisted) and a green-path test (silent persist, no notify).
  Both use explicit assertions and `refute_receive` — no error-hiding. The
  `result_store_contract` roundtrip and `fake_adapter` warm-marker helpers are sound.
- **Docs / CHANGELOG** — CHANGELOG `Added` entry, `docs/agent-gate-workflow.md`,
  `docs/dogfooding-workflow.md`, `Audit` `@moduledoc`, and `skills/harness-driver`
  all updated coherently. The Task 252 `warm_paths` CHANGELOG line was correctly
  amended to note audit worktrees are now intentionally cold.

## Cold build

`mix compile --warnings-as-errors` from this cold (un-warmed) audit checkout
compiled all 153 files with zero warnings.

## Findings

None. Naming is consistent, docs are complete, no dead code, no leftover debug
output, no broken conventions. No discovery tasks filed.

## Reviewer-rejection note

The recent reviewer rejection surfaced in the loop (task 208, run
run-1780839809032-86dd1f20) is unrelated to this range — it concerns a coverage
threshold on a different task and is not a false rejection bearing on Task 318.
