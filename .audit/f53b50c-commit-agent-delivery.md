---
sha: f53b50c51cc9b5aadc62591becef6af1b08cfd35
short_sha: f53b50c
audited_at: 2026-05-21
auditor_model: claude-opus-4-7
verdict: clean
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: fix: commit agent delivery to run branch before teardown (Task 24)

**Original commit:** f53b50c — `fix: commit agent delivery to run branch before teardown (Task 24)`
**Author:** E.FU
**Files touched:** 13
**LOC:** +278 / -33

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | — | follow-up | lib/harness/worktree.ex (`commit/2`) | `commit/2` commits whatever branch HEAD currently points at; if the agent runs `git switch`/detaches HEAD, the work lands off `harness/<id>` and teardown loses the deliverable | Not auto-fixed — see follow-up note below |

## Auto-applied fixes

- (none)

## Discuss-tier resolutions

- **Finding 1 (`discuss-design`, divergence → dropped + recorded as follow-up):**
  Codex rated it pri 8. Claude agrees it is a real robustness gap — the whole
  deliverable model assumes the agent's work lands on `harness/<id>` — but the
  trigger (an agent that moves HEAD) is uncommon, and the fix has open options
  (assert HEAD is on the expected branch and fail `{:commit_failed, :head_moved}`,
  vs. force-checkout the branch, vs. capture via an explicit branch ref). The
  ripple (a new `Worktree.error/0` variant, new `committing`-state handling)
  makes it more than a mechanical fix. Divergence on the fix shape → not
  auto-applied.
  **Audit-surfaced follow-up (not filed as an rmap task — `roadmap/tasks.toml`
  is mid-edit by a concurrent agent; file when the roadmap is clean):**
  *"`Harness.Worktree.commit/2` should pin its commit to the worktree's own
  `harness/<id>` branch (or fail loudly) so an agent moving HEAD cannot strand
  the run's deliverable."*

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: —
Codex-only findings (verified): 1 (`commit/2` wrong-branch — verified; latent,
  see above)
Codex-only findings (discarded as over-flag):
- `ROADMAP.md:12` focus block stale (pri 4) — **discarded.** Committed
  `ROADMAP.md` is in sync with `roadmap/tasks.toml` (`rmap validate
  --check-render` → `valid`).
