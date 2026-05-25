---
sha: 94141531f39fade3a9899cd600cfcf56eea1f6d9
short_sha: 9414153
audited_at: 2026-05-25
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: harness: agent delivery — task 32 Antigravity adapter does not isolate to its run worktree

**Original commit:** 9414153 — `harness: agent delivery — task 32 Antigravity adapter does not isolate to its run worktree (run run-1779629242138-527b2145)`
**Author:** harness
**Files touched:** 11
**LOC:** +242 / -16

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 7 | bug | lib/harness/run.ex:349 | `running/3` `:DOWN` handler (driver crash) skips `checkout_pollution_reason/1`, so an agent that pollutes the checkout then crashes the driver settles as `{:driver_crashed, _}` and loses the pollution signal | applied — HIGH-tier grader (Codex) approved |
| 2 | 6 | doc-gap | lib/harness/worktree/isolation.ex:48 | `check_pollution/2` `@spec` omits `{:error, {:checkout_pollution_check_failed, _}}` which the implementation can return when post-run `snapshot/1` fails | applied |
| 3 | 5 | doc-gap | lib/harness/run/result.ex:30 | Result.reason doc bullet says `:checkout_polluted` (atom) but the actual reason type is `{:checkout_polluted, String.t()}` (tagged); also `{:checkout_pollution_check_failed, _}` is reachable but absent from the union | applied |
| 4 | 4 | doc-gap | docs/dogfooding-workflow.md:215 | Verdict table lists every harness-failure reason except the new `{:checkout_polluted, _}` and `{:checkout_pollution_check_failed, _}` — leaves dogfooders without classification guidance | applied |
| 5 | — | discuss-trivial | lib/harness/worktree/isolation.ex:39 | `snapshot/1` uses default `git status --porcelain` which misses ignored files and may miss new files under pre-existing untracked dirs | dropped — defended: the design protects against an `agy`-class adapter that writes inside tracked-or-newly-untracked paths; widening to `-uall --ignored` would inflate snapshots for `.gitignore`'d build artefacts (`_build`, `priv/plts`, deps) that change every test run, producing false-positive pollution. Keep current scope; revisit if a real false-negative pollution case appears |
| 6 | — | discuss | lib/harness/worktree/isolation.ex:52 | Snapshot-diff design can't distinguish adapter pollution from unrelated parallel writes in the main checkout | accepted as design — runs go through `Run` gen_statem with one checkout context; concurrent edits from a separate user session are out of harness's control, and the conservative bias (fail on unexpected change) is correct for the worktree-isolation guarantee |

## Auto-applied fixes

- **lib/harness/run.ex:349** — `running/3` driver-crash handler now calls `checkout_pollution_reason(data)` and uses `pollution_reason || {:driver_crashed, reason}` for the failure reason, mirroring the existing precedence in `do_cancel/3` (line ~511) and the lifetime-timeout path (line ~533). Comment added at the call site to explain the precedence. **HIGH-tier grader (Codex) approve verdict** recorded below — Codex verified precedence consistency across all three pollution-checking sites and confirmed focused tests (`test/harness/run_test.exs` + `test/harness/worktree/isolation_test.exs`) still pass 35/35.
- **lib/harness/worktree/isolation.ex:48** — `check_pollution/2` `@spec` widened to enumerate `:ok | {:error, {:checkout_polluted, String.t()}} | {:error, {:checkout_pollution_check_failed, Git.error()}}`; `@doc` updated to describe the conservative-failure rationale.
- **lib/harness/run/result.ex:30** — Result.reason doc bullet for `:checkout_polluted` rewritten to `{:checkout_polluted, status}` with the post-run porcelain semantics; new bullet added for `{:checkout_pollution_check_failed, r}` describing the conservative-failure path. Type union extended with `{:checkout_pollution_check_failed, term()}` so dialyzer sees the full reachable shape.
- **docs/dogfooding-workflow.md:215** — Verdict table gained two new rows: `{:checkout_polluted, status}` (agent bug, harness trap fired by design — NOT a harness bug) and `{:checkout_pollution_check_failed, _}` (rare; transient git/IO issue, re-run + inspect).

## Discuss-tier resolutions

- (none escalated) Two `discuss`-tier rows (snapshot scope, parallel-write disambiguation) accepted as design with rationale recorded above. Neither is reversible-divergence in the audit sense — both are deliberate trade-offs the original Task 32 design landed on.

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: 1 (driver-crash pollution skip — Codex Pri-7, Claude independently flagged the missed pollution path; bumped from Codex Pri-7 → applied Pri-7), 2 (Isolation spec — Codex Pri-6, Claude independently flagged the spec gap)
Codex-only findings (verified): 3 (Result.reason doc), 4 (verdict table) — both verified against current code + docs, applied
Codex-only findings (discarded as over-flag): 5 (snapshot `-uall --ignored`) — verified against the design intent and dropped with rationale; would create real false positives on `.gitignore`d build artefacts

## HIGH-tier grader verdict (Run.ex pollution fix)

**Codex grader: approve.**

> Verified the :DOWN driver-crash path now calls `checkout_pollution_reason/1` and uses `pollution_reason || {:driver_crashed, reason}`, matching the existing precedence in both `do_cancel/3` and the lifetime-timeout path. `checkout_pollution_reason/1` returns nil on `:ok` and the pollution reason on error, so the precedence works as intended, and the focused `mix test.json` run passed 35/35 tests.

Grader job: `task-mpkir6hg-yrw31d` (Codex; different-agent grader per stake-gated ladder, this audit ran on Claude).
