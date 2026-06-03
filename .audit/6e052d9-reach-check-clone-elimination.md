---
sha: 6e052d90d576daa218c0b1d48ec60723485f7c29
short_sha: 6e052d9
audited_at: 2026-06-03
auditor_model: claude-opus-4-8
verdict: clean
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: harness: reach.check arch pass + ex_dna clone elimination (10→0) — LineParser/TermCodec consolidation

**Original commit:** 6e052d9 — `harness: reach.check arch pass + ex_dna clone elimination (10→0) — LineParser/TermCodec consolidation`
**Author:** E.FU
**Files touched:** 35
**LOC:** +560 / −560 (symmetric — behavior-preserving refactor)

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| — | —   | —        | —         | No verified findings | — |

## Summary

A clean, behavior-preserving static-analysis + clone-elimination pass. Both reviewers (Claude + Codex) independently confirmed no behavior drift:

- **`Harness.LineParser` (new)** wraps the kept `Harness.LineBuffer` (`split/2` + `take_remainder/1`); the five NDJSON parsers route through it via a `use` macro and `Harness.Chat.Claude.StreamParser` uses it directly. The decode/translate/invalid-line paths are preserved exactly: empty lines → `[]`, dashboard parsers preserve undecodable lines as `{:unknown, %{raw: line}}` (`Parser.unknown_line/1`), StreamParser drops them (`drop_invalid/1`) — matching each module's prior behavior.
- **`Harness.TermCodec.read_file/1` + `write_file/2` (new)** collapse six copy-pasted `.tmp`+rename term stores (Agent/Cron/Landing settings, Chat.Store, ResultStore.File, import-results task). Error shapes preserved: `{:error, :enoent}` posix passthrough, `{:error, {:invalid_term_file, path}}` on torn bytes, no-`[:safe]` decode for cross-version atom drift. New round-trip test coverage added (`test/harness/term_codec_test.exs`).
- **Three 2-site clones lifted:** `Project.local_repo_path/1` (Audit + Lander), `Oban.put_env_arg/2` (Batch + Run.Worker), `ResultStore.pop_limit/1` (File + Postgres) — each a verbatim move.
- **Smell fixes** (ChatLive prepend-and-reverse, CompareLive pair-iteration, ConfigInspector clause split, RunDiff pattern discard, Worktree `match?/2`) — all behavior-equivalent.
- **CHANGELOG:** the removed `### Fixed` subheading folds the Lander.Worker bullet into `### Changed`; both bullets describe refactors/consolidation, so `### Changed` is the correct Keep-a-Changelog category. Not a finding.

## Auto-applied fixes

- (none — no findings)

## Discuss-tier resolutions

- (none)

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: —
Codex-only findings (verified): —
Codex-only findings (discarded as over-flag): —
Note: Codex could not run `mix test.json` / `mix credo` in its sandbox (Hex/`:descripex` SCM load failure + socket `:eperm`); its verdict is read-based. Claude verified the equivalence by reading the new modules against the deleted per-module copies. The diff was already hook-graded (format/compile/credo/dialyzer/test) at commit time.
