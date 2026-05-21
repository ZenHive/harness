---
sha: 25ed7958c031d5f39e3a49cc1095a6be62382f6f
short_sha: 25ed795
audited_at: 2026-05-21
auditor_model: claude-opus-4-7
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: feat: Antigravity headless adapter

**Original commit:** 25ed795 — `feat: Antigravity headless adapter`
**Author:** E.FU
**Files touched:** 7
**LOC:** +186 / -6

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 6 | bug | lib/harness/roadmap.ex:33 | `:antigravity` added to `@valid_agents`, but `rmap delegate --to` accepts only claude/codex/cursor — so `ingest(agent: :antigravity)` passes harness validation then dies with an opaque `{:rmap_failed, _}` | Applied: `:antigravity` reverted from the ingest surface + regression test added |
| 2 | 5 | doc-gap | CLAUDE.md (Agent Headless Entry Points table) | The table lists four agents and the prose says "All four are driven over OTP Ports"; Antigravity is a fifth adapter | Not auto-applied — see notes |
| 3 | 4 | doc-gap | README.md:5 | Overview parenthetical listed four agents while the Status section lists five | Applied: Antigravity added to the overview |
| 4 | — | doc-gap | docs/agent-cli-reference.md | Dated four-agent research snapshot does not cover Antigravity | Not auto-applied — see notes |
| 5 | — | abstraction (tracked) | lib/harness/agent_adapter/antigravity.ex | `classify_message/2` / `terminate/1` repeat across all 5 adapters | No action — tracked as Task 27 |

## Auto-applied fixes

- `lib/harness/roadmap.ex` — `@valid_agents` reverted to `[:claude, :codex,
  :cursor]` (with a comment pinning the rationale to `rmap delegate --to`'s
  accepted values); the `ingest/2` `:agent` docstring updated to match.
- `lib/harness/roadmap/item.ex` — `Item.agent` type reverted to
  `:claude | :codex | :cursor`.
- `test/harness/roadmap_test.exs` — added a regression test asserting
  `ingest(agent: :antigravity)` returns `{:error, {:invalid_agent,
  :antigravity}}`, mirroring the existing `:grok` test.
- `README.md` — the overview paragraph's agent list now includes Antigravity
  (it was already in the Status section — this removes the in-file
  inconsistency).

## Discuss-tier resolutions

- (none — finding 1 is a corroborated, Codex-verified bug; the fix is the
  correct, design-grounded resolution. `Harness.Roadmap` deliberately shells
  out to `rmap delegate` to render prompts — rmap owns the prompt template — so
  `@valid_agents` *must* mirror `rmap delegate --to`. Task 26's acceptance
  criterion 6 asked for the `:antigravity` integration, but that criterion
  conflicts with the rmap-owns-rendering design; following it produced a broken
  path. The Grok adapter (`50c1b77`) set the correct precedent: an adapter
  rmap cannot delegate to is *not* an ingest agent — it runs with a
  claude/codex/cursor-rendered prompt dispatched directly via
  `Harness.Run.start_run/4`.)

## Notes — doc gaps not auto-applied

Findings 2 and 4 are real drift but were **not** auto-applied, to avoid
fabricating un-verified `agy` CLI facts (`critical-rules.md` § Integrity):

- **CLAUDE.md** "Agent Headless Entry Points" table — completing a fifth row
  needs Antigravity's raw-output-format fact; the adapter passes *no*
  `--output-format` flag, so the cell has no verifiable value. CLAUDE.md is the
  maintainer's curated instruction file — the "All four" → "five" correction
  and the new table row are left for the maintainer.
- **docs/agent-cli-reference.md** — a dated (2026-05-20), scope-defined research
  snapshot for Tasks 4/13/14/15; extending it with Antigravity needs verified
  CLI facts, not transcribed adapter claims.

## Audit-surfaced follow-up (not filed)

Not filed as an rmap task — `roadmap/tasks.toml` is mid-edit by a concurrent
agent. File when the roadmap is clean:
*"rmap `delegate --to` supports only claude/codex/cursor; harness has Grok and
Antigravity adapters with no ingest path. Decide: extend rmap's delegate
surface, or formally accept that non-delegatable adapters run with a
claude/codex/cursor-rendered prompt."*

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: 1 (Codex independently flagged the `:antigravity` ingest
  bug at pri 8 and **verified it directly**: "`rmap delegate 1 --to antigravity`
  reports possible values claude, codex, cursor"); 3 (README inconsistency)
Codex-only findings (verified): 2, 4 (CLAUDE.md + agent-cli-reference drift —
  verified; handled as notes per Integrity, see above)
Codex-only findings (discarded as over-flag):
- `antigravity.ex:79` adapter-callback duplication marked `discuss` — Codex
  itself noted it is "already tracked by the roadmap" (Task 27). No action.
