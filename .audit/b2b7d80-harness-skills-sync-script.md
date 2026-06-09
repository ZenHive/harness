---
sha: b2b7d800586163ca3fdca0ad7e6575fcd99a420b
short_sha: b2b7d80
audited_at: 2026-06-09
auditor_model: claude-opus-4-8
verdict: clean
codex_status: single-reviewer (no lib/ code — outside batched Codex payload)
audited_by: audit-review v1
---

# Audit: harness skills: add sync-harness-skills.sh; document canonical-here propagation; workflow roster cursor-rebalance

**Original commit:** b2b7d80 — `harness skills: add sync-harness-skills.sh; ...`
**Author:** E.FU
**Files touched:** CLAUDE.md, priv/includes/harness-workflow.md, scripts/sync-harness-skills.sh
**LOC:** ±127

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| — | —   | (none)   | —         | New bash sync script + doc updates; no production (`lib/`) code | clean |

## Notes

`scripts/sync-harness-skills.sh` reviewed against Categories 1-6:
- `set -euo pipefail`; final `[[ "$errors" -eq 0 ]]` is the load-bearing exit status (correct).
- `--dry-run` parsed from `$1` only — matches the documented single-flag usage; not a bug.
- `sync_skill_body` preserves the DEST frontmatter (awk to the 2nd `---`), validates it, and trims leading blank lines on the stripped source body — correct frontmatter-preservation semantics.
- Marketplace legs skip gracefully when `$CLAUDE_MARKETPLACE_DIR` is absent; `~/.claude/includes` leg always runs. Matches the moduledoc contract.
- No magic-weight scoring / judgment-in-code (THE MANTRA holds; this is mechanical propagation).

Classified full-audit by LOC (127 ≥ 100) but touches no `lib/`, so excluded from the batched Codex second-opinion payload (which covers the four lib-bearing commits). Single-reviewer pass — no findings.
