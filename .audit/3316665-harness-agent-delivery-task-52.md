---
sha: 3316665a34331c5c2bff6a1976acc213bc0afacb
short_sha: 3316665
audited_at: 2026-05-25
auditor_model: claude-opus-4-7
verdict: clean
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: harness: agent delivery — task 52 Add pi.dev headless adapter

**Original commit:** 3316665 — `harness: agent delivery — task 52 Add pi.dev headless adapter (run run-1779629242126-44831b1a)`
**Author:** harness
**Files touched:** 4 (net-new `lib/harness/agent_adapter/pi.ex` + 2 test files + CLAUDE.md status paragraph)
**LOC:** +208 / -2

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | — | discuss-design | lib/harness/agent_adapter/pi.ex:107 | (Codex) Bare `--continue` has no run-scoped session selector; wire `--session-dir`/`--session` so repair attempts cannot resume an unrelated pi session | **dropped — verified false-positive in-session** |
| 2 | — | discuss | test/harness/agent_adapter/pi_test.exs:54 | (Codex) Resume tests lock in bare `--continue` argv but don't assert a run-scoped session selector | dropped — follows finding #1 |

## Auto-applied fixes

- (none) — both Codex-only findings verified against pi-cli's actual session-storage model and dropped with rationale.

## Discuss-tier resolutions

**Finding #1 — pi `--continue` session scoping.** Codex flagged that bare `--continue` may resume an unrelated pi session if pi stores sessions globally. The Pi adapter's docstring claims "same reasoning as the Claude adapter's `--continue`" (cwd-scoped).

**In-session verification (instead of stopping for user):** Ran `pi --help` and inspected the local pi installation. Pi exposes `--session-dir`, `--session`, and `PI_CODING_AGENT_SESSION_DIR` env var — the flags Codex proposed are real. **But** the default session-storage layout is per-cwd: sessions land under `~/.pi/agent/sessions/<path-mangled-cwd>/<timestamp>_<uuid>.jsonl`. Confirmed empirically by inspecting `~/.pi/agent/sessions/` — buckets exist for every cwd pi has been invoked from (e.g. `--Users-efries-_DATA-code-harness--`, `--Users-efries-_DATA-code-zen_websocket--`). `pi --continue` therefore selects the most-recent session *within the current cwd's bucket*, which for a harness run is the unique session in the run's worktree — exactly the invariant the Pi adapter's docstring describes and the same semantics as Claude's `--continue`.

**Codex's finding is therefore an over-flag** rooted in not having verified pi's default storage layout. The fix Codex proposed (thread `--session-dir`/`--session` through `Invocation`) would couple the harness contract to pi-cli specifics for zero correctness gain — sessions are already cwd-isolated by construction, and each harness run owns a unique worktree path. No code change.

**Reversibility:** since verification resolved the divergence, this is no longer a discuss-design fork — it's a confirmed-clean Codex-only over-flag. Logging here so a future audit doesn't re-raise the same concern.

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: —
Codex-only findings (verified): 1 (`--continue` scoping — verified against `~/.pi/agent/sessions/` layout, dropped with rationale)
Codex-only findings (discarded as over-flag): 1 (same finding — the verification reclassified it from "discuss-design pending verification" to "dropped over-flag")
