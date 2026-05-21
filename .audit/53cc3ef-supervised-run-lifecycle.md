---
sha: 53cc3ef2b32694ab8de28de55f277647bd17eb9f
short_sha: 53cc3ef
audited_at: 2026-05-21
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: feat: supervised run lifecycle gen_statem + DynamicSupervisor (Task 8)

**Original commit:** 53cc3ef — `feat: supervised run lifecycle gen_statem + DynamicSupervisor (Task 8)`
**Author:** E.FU
**Files touched:** 15
**LOC:** +1289 / -22

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 3 | doc-gap | lib/harness/run/status.ex:24 | `agent_os_pid` doc says "nil … after it has terminated"; the field actually holds the spawn-time pid through the terminal states | Applied: docstring corrected |
| 2 | — | bug (within-range fixed) | lib/harness/run.ex (`running`→`verifying`) | A successful agent's edits were never committed before verification/teardown — the `harness/<id>` branch could end with no delivery commit | No action — fixed by `f53b50c` (Task 24, `committing` state) |
| 3 | — | follow-up | lib/harness/run.ex (`handle_common` lifetime timeout) | If `{:run_handle}` never arrives (a hung `build_command`/`invoke`), the lifetime timeout defers instead of force-settling — the last-resort budget is not enforced | Not auto-fixed — see follow-up note below |

## Auto-applied fixes

- `lib/harness/run/status.ex` — `agent_os_pid` docstring now states it is the
  spawn-time pid, `nil` only before spawn or after a cancellation/failure clears
  the run handle, and otherwise retained through `verifying` and the terminal
  states.

## Discuss-tier resolutions

- **Finding 3 (`discuss-design`, divergence → dropped + recorded as follow-up):**
  Codex rated the deferred-lifetime-timeout hole pri 8; Claude assessed it as a
  latent robustness gap not reachable with the shipped adapters (`build_command`
  is pure and fast for all of them, so `{:run_handle}` always arrives within
  milliseconds). The fix is a genuine design call — force-settle on the
  lifetime timeout and risk orphaning a just-spawned agent to the sweeper, vs.
  the current defer-and-wait. Divergence on fix-now-vs-defer → not auto-applied.
  **Audit-surfaced follow-up (not filed as an rmap task — `roadmap/tasks.toml`
  is mid-edit by a concurrent agent; file when the roadmap is clean):**
  *"Harden the `Harness.Run` lifetime timeout so it force-settles even when the
  agent run handle never arrives (a hung `build_command`/`invoke`)."*

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: — (finding 1 raised by both Claude and Codex)
Codex-only findings (verified): 3 (deferred-lifetime-timeout hole — verified
  against the `handle_common` clauses; latent, see above)
Codex-only findings (discarded as over-flag):
- `run.ex:263` agent edits never committed (pri 9) — **not discarded; within
  range.** Real, but `f53b50c` (the next-but-one commit) adds the `committing`
  state that fixes it. Codex audited 53cc3ef in isolation.
- `README.md:11` stale after Task 8 (pri 2) — **discarded.** Point-in-time;
  the README at HEAD describes the supervised run lifecycle and all five
  adapters.
