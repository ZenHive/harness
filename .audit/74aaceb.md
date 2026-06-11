# Audit 74aaceb (Task 251 Discovery-filing stage)

**Range audited (already landed on development):**
- 308777d harness: agent delivery — task 251 Discovery-filing stage: implementer/reviewer/audit agents file follow-ups via rmap new, not lose them or bury them in TODO comments (run run-1781216081950-cad81b07)
- 74aaceb roadmap: task 251 -> done (shipped 308777df2f4e)

(roadmap marker commits touch only `roadmap/*` and `ROADMAP.md` and are excluded from edit scope per operational rules.)

**Delivery commit reviewed (non-roadmap diff):**
- 308777d — 8 files changed, +265/-6: new `lib/harness/rmap_path.ex`, updates to `lib/harness/{run.ex,audit.ex}`, `docs/agent-gate-workflow.md`, tests in `test/harness/{run_test,audit_test,roadmap_test}.exs`, and `test/support/fake_adapter.ex`.

## Scope of review
- Full unified diff of 308777d.
- Hygiene targets: dead code, missing/stale docs, CHANGELOG gaps, leftover debug IO, broken project conventions (Elixir @spec on def+defp, @moduledoc/@doc floor, TODO(Task N) only, no IO in @doc, useful tests), inconsistent naming, the "implementer" claim in task title vs what actually landed, the reviewer-quality feedback loop note supplied in the query.
- Cross-checked that new surfaces follow the "mechanical substrate only" mantra (harness supplies reachability + prompt framing; agents decide what to file).
- No edits to `roadmap/tasks.toml`, `ROADMAP.md`, or `data.json`.

## Findings

### Actionable hygiene (fixed)
1. **CHANGELOG gap for Task 251.** The agent delivery introduced a new internal module, PATH-munging for three agent roles, and prompt instructions, yet added nothing under `[Unreleased]`. Added a concise, style-matched `### Added` bullet (placed first under the section) describing the mechanism, the framing for reviewer+audit, the canonical rules update (see below), test coverage, and the concurrency/lander implications. Matches the pattern of prior audit fixes for 245/246/249.
2. **Implementer discovery-filing instruction absent from canonical rules (inconsistent with task title and commit message).** Task 251 title and the delivery commit message explicitly include "implementer/reviewer/audit agents". The landed changes correctly added "Discovery filing:" paragraphs to the *reviewer* prompt (in `run.ex`) and the *audit* prompt (in `audit.ex`), plus the supporting doc paragraph. However `priv/agent_rules/canonical.md` (the `@external_resource` source rendered into implementer invocations via `AgentRules` for all six adapters) received no update. Implementers therefore did not receive the parallel directive. Added a matching bullet under the `<!-- @section operational -->` "Harness operation" list so the implementer rules now instruct: use `rmap new --from-stdin ...` for genuine follow-ups instead of TODOs or prose; this is additive and does not conflict with the "Never touch the roadmap" rule (which guards the *current* task's status). The rules change is the minimal forward completion of the advertised surface.

### Notes (no action)
- **New module `Harness.RmapPath`.** 54 LOC, single public entrypoint `ensure_agent_env/1` correctly marked `@doc false` + `@spec`, all helpers carry `@spec`, concise moduledoc stating the "no judgment" intent. `rmap_dirs/0` filters at call time to only dirs that actually contain the binary (defensive). Prepends discovered dirs ahead of existing PATH (correct priority). Used exactly twice (Run `in_run_env` for reviewer+implementer paths; Audit `invocation` for auditor). Test-only app-env escape hatch (`:rmap_path_dirs`) is fine for an advanced operator knob; no config/docs drift introduced because none was claimed.
- **Tests are useful and non-trivial.** Prompt-content tests assert the exact new instruction phrases (including the project-specific `roadmap_path` interpolation) appear in the framed reviewer and audit prompts. Scrubbed-PATH tests (both reviewer and audit) use dedicated fake-adapter commands that capture `command -v rmap` inside the worktree and assert the injected dir won. The `roadmap_test` "rmap new discovery filing" case actually shells the real `rmap` binary (via `--from-stdin --tasks-path`) with a realistic `[[task]]` fragment and round-trips it through `rmap show --json` — directly validates the "filed task is parseable" requirement. Duplicated 15-line test helpers (`fake_rmap_dir` + `with_rmap_path_dirs`) exist in `run_test.exs` and `audit_test.exs`; minor, test-local, not worth extracting for a hygiene pass.
- **No other material hygiene issues.** No dead code (new module and prompt text are live and covered), no stray `IO.puts`/debug, no bare `TODO`s, naming consistent (`review_capture_rmap_path`, `audit_capture_rmap_path`, `ensure_agent_env`), @spec/@doc coverage on touched surfaces follows the project floor, moduledocs were not made stale. The doc addition in `agent-gate-workflow.md` correctly notes that concurrent `tasks.toml` edits from parallel discovery filings fall through to the existing `Lander.Resolver` (no new locking). The `fake_adapter` comment updates are accurate.
- **Reviewer rejection note (task 208):** The supplied example ("Rescue-pass review only. ... coverage was 79.47%, below the configured 80.0% threshold. ... I made no implementation changes") is for task 208 / run run-1780839809032-86dd1f20. That task id and run are outside the audited range (only 251). Not applicable; the 251 delivery itself was a clean, well-tested agent delivery with no similar coverage or "no changes" signals.
- **Roadmap marker 74aaceb:** Pure status bookkeeping (as intended). Per rules, left untouched.
- **Code quality / mantra adherence:** The delivery is minimal and judgment-free. Harness only does mechanical PATH construction and prompt framing; the AI agents (implementer during work, reviewer at gate, audit in post-merge) decide whether/ what to file. Matches the "count facts in code; write the *meaning* of facts with an AI" leitmotif. Prior audit precedent followed.

**Outcome:** Range was nearly clean. The two gaps above were the only items worth a minimal forward fix (CHANGELOG omission + completing the implementer rules surface advertised by the task). Both fixes are small, targeted, and leave the diff ready to commit. Targeted tests (run/audit/roadmap) all passed (174/174); `mix format --check-formatted && mix compile --warnings-as-errors` clean. No reverts, no scope creep, no roadmap edits, no disabled checks.

This `audit(74aaceb): ...` commit becomes the anchor for the next post-merge audit sweep.
