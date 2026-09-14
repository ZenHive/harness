<!-- @section operational -->
# Harness operation

You are being driven by **harness**, an OTP-native orchestrator that dispatched this session into an isolated git worktree. Your role for this session — implementer, reviewer, recovery, merge-conflict resolver, or post-merge audit — is stated in the prompt; these rules apply to every role.

- **The reviewer AI is the gate.** Implementer work is committed by harness and reviewed by a cross-family reviewer agent that runs the project's checks itself, fixes inline, and writes the verdict. Success is the reviewer approving — never a self-reported result, never a process exit code. Do not skip, weaken, or evade checks; the reviewer also rates the implementer's truthfulness against what it finds.
- **Work in the assigned worktree only.** Every file edit belongs in the current working directory.
- **Leave the roadmap and changelog alone.** Harness resets `roadmap/tasks.toml`, `roadmap/data.json`, `ROADMAP.md`, and `CHANGELOG.md` to HEAD before it commits, so an edit to any of them — including `rmap new` or a status change — is lost. Harness writes the task outcome back after the reviewer approves and the work lands. Mention follow-up work you notice in your final report; the reviewer records it as `proposed_tasks` and the orchestrator files what is warranted.
- **Fix-forward after merge.** A post-merge audit agent sweeps landed commits and commits hygiene fixes forward; it never reverts or unmerges.

<!-- @section methodology -->
# Development methodology

- **Minimal viable diff.** Implement the smallest correct change. Do not refactor, reformat, or expand scope beyond what the task requires.
- **Match existing conventions.** Read surrounding code before writing; additions should read as if written by the same author.
- **If the task as specified is wrong**, say so in your final report and implement the closest correct thing — there is no user turn to ask.
- **No evasion.** Do not disable checks, skip tests, `@tag :skip` failures away, or `# credo:disable` without fixing the underlying issue. Do not hide errors in tests.
- **Useful tests only.** Cover real behavior, edge cases, and error paths — not tests that trivially assert the obvious or pass on every outcome.
- **Comments sparingly.** Comment non-obvious business logic or deep technical details only.

<!-- @section elixir -->
# Elixir conventions

- Every public function gets a `@spec`. Use tagged tuples for errors: `{:ok, result}` or `{:error, reason}`.
- Modules get concise `@moduledoc`; functions get a one-line `@doc` when the name is not enough.
- Prefer functional, declarative style with pattern matching.
- Doctests document happy-path API usage; ExUnit tests cover boundaries, unions, invariants, and error paths.
- Use `TODO(Task N)` for temporary work tied to roadmap items — never bare `TODO`.

<!-- @section verification_gates -->
# Check expectations (reviewer-graded — not agent-honor)

The reviewer runs the target project's own checks after you finish and judges the output. You do not need to memorize or self-enforce numeric gates — but work that fails them costs the reviewer fix time and lowers your ratings.

- Coverage thresholds (80% standard / 95% critical modules)
- `mix credo --strict`, `mix dialyzer`, `mix doctor`, `mix sobelow`
- Format and compile-with-warnings-as-errors gates
