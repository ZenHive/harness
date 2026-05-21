---
sha: 058e242c2997ad1cc689a3634e16fd1e3ea12eff
short_sha: 058e242
audited_at: 2026-05-21
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: fix: immediate-EOF stdin for Port-spawned agents (Task 23)

**Original commit:** 058e242 — `fix: immediate-EOF stdin for Port-spawned agents (Task 23)`
**Author:** E.FU
**Files touched:** 11
**LOC:** +313 / -23

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 3 | doc-gap | README.md:32 | Dev-loop documents `mix sobelow --exit Low`; this commit's verifier preset uses `mix sobelow --exit --skip`, so a human run re-reports the repo's `# sobelow_skip` findings | Applied: README aligned to `--exit --skip` |

## Auto-applied fixes

- `README.md` — the Development quality loop now shows `mix sobelow --exit
  --skip`, matching the verification preset this commit changed (so the repo's
  inline `# sobelow_skip` annotations are honoured by a manual run too).

The `:stderr_to_stdout` capture fix also lands on this commit's
`spawn_run/5` (it last touched that `Port.open`); it is recorded against the
originating commit — see `.audit/c219d4f-define-the-agentadapter.md`.

## Discuss-tier resolutions

- (none)

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: —
Codex-only findings (verified): 1 (README sobelow command — verified against
  the `@elixir_preset` change in the same commit)
Codex confirmed the core fix is sound: "the `sh -c 'exec "$0" "$@" </dev/null'`
argument shape is correct, preserves argv as positional params, and `exec` keeps
the same OS pid for termination."
Codex-only findings (discarded as over-flag):
- `ROADMAP.md:16` focus block stale (pri 4) — **discarded.** Committed
  `ROADMAP.md` is in sync with `roadmap/tasks.toml`.
