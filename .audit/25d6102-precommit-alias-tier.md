---
sha: 25d610200984bfc55ab6334075a4b7849ea0f2d9
short_sha: 25d6102
audited_at: 2026-05-27
auditor_model: claude-opus-4-7
verdict: clean
codex_status: not-dispatched (tight pass — user directive)
audited_by: audit-review v1
---

# Audit: harness: precommit alias + tier (check.fast) mirroring CI harness.yml gate

**Original commit:** 25d6102 — `harness: precommit alias + tier (check.fast) mirroring CI harness.yml gate`
**Author:** E.FU
**Files touched:** 5 (1 lib, 2 test/support, mix.exs)
**LOC:** +216 / -40

## Findings

None substantive.

- `check.fast` / `precommit` aliases mirror the CI workflow gate — flag sets match `elixir-ci-harness` (credo `--ignore TagTODO,TagFIXME`, `--exclude integration` on test run, threshold 80 with documented rationale for the Phase-7 Postgres/Oban exclusion).
- `project_registry.ex` fixes the `is_atom(nil) == true` bug in `fetch_check_stack/1` (added `and not is_nil(...)`) AND adds the missing non-binary clause to `fetch_roadmap_path/1`. Both fixes carry inline rationale comments — together they close the type-validation hole noted in `2bce2a2`'s audit (Finding #1).
- `agent_adapter/conformance_case.ex` extraction of rule-delivery dispatch into a sibling module to avoid Elixir 1.18 gradual-type dead-code warnings — sensible defensive refactor.
- Cover threshold is pinned at 80 (vs 85 project default) with a clearly-marked condition for raising it once Phase-7 integration tests have a live DB in CI. The reason is captured inline; appropriate scope discipline.

## Auto-applied fixes

— None.

## Codex second-opinion

Status: not-dispatched (user-directed tight pass; infrastructure commit, verification stack signal sufficient)
