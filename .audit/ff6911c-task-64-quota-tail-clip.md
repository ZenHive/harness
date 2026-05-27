---
sha: ff6911cc4539d899be10cf2ef9e6c21089acc02f
short_sha: ff6911c
audited_at: 2026-05-27
auditor_model: claude-opus-4-7
verdict: clean
codex_status: not-dispatched (tight pass — narrow, well-tested classifier fix)
audited_by: audit-review v1
---

# Audit: harness: failure_class — clip outcome + verdict text to trailing 4 KiB before quota match (task 64)

**Original commit:** ff6911c — `harness: failure_class — clip outcome + verdict text to trailing 4 KiB before quota match (task 64)`
**Author:** E.FU
**Files touched:** 2 (lib/harness/run/failure_class.ex, test/harness/run/retry_policy_test.exs)
**LOC:** +84

## Findings

None. Task 64 is the recovery-mechanism fix: agents constantly read source/docs containing `quota`, `rate limit`, `subscription`, etc., which made `FailureClass.collect_text/1` false-positive on benign mid-run reads and short-circuited the repair loop. The diff:

- New `@text_tail_bytes 4 * 1024` constant + private `tail/1` helper using `binary_part(text, size - 4096, 4096)` to keep just the trailing window.
- `outcome_text/1` and `verdict_text/1` both call `tail/1` before joining for regex match.
- Three regression tests: middle-of-transcript `quota` words classify `:terminal` (not `:quota_exhausted`); tail-of-transcript `billing_error` envelope still classifies `:quota_exhausted`; verification stdout with middle-of-output `quota` doesn't falsely classify either.

Spot-checked: `binary_part/3` on UTF-8 may split mid-codepoint at the head boundary, but the downstream regex matches ASCII quota tokens, so codepoint integrity isn't load-bearing. Acceptable trade-off.

## Auto-applied fixes

— None needed.

## Discuss-tier resolutions

— None.

## Codex second-opinion

Status: not-dispatched. 84 LOC across one production file + one test file, with regression coverage that directly proves the false-positive scenario it fixes.
