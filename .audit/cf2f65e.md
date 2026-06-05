# Audit — cf2f65e (range cf2f65e~24..cf2f65e)

Post-merge hygiene pass over 24 landed commits (Tasks 203–207, 215, plus phase-17
roadmap + lander/review fixes). ~3,279 insertions across 49 files.

## Reviewed

- **Debug output / leftover instrumentation** — grepped added `lib/` lines for
  `IO.inspect` / `IO.puts` / `dbg(` / stray `Logger.debug`. None.
- **Bare `TODO` without `TODO:`/`TODO(Task N)` prefix** — none in added lib/test.
- **Dead/leftover files** — the `CLAUDE.full.md` / `CLAUDE.lean.md` A/B variants
  were correctly deleted (344348c); only `CLAUDE.md` remains. Good.
- **New-module convention hygiene** — `Harness.Roadmap.Durable` (12 funcs/12 specs,
  `@moduledoc`) and `Harness.Git.TargetSync` (9 funcs/9 specs, `@moduledoc`) both
  fully `@spec`'d (def + defp) per repo mandate. Clean.
- **Roadmap parse health** — `rmap list` parses `tasks.toml` cleanly; landed tasks
  (205/206/207/215) carry proper `done` + outcome fields. No corruption.
- **CHANGELOG coverage** — cross-checked each landed task against the Unreleased
  section. Tasks 203, 204, 205, 206, 215 covered. Two gaps found and fixed (below).
- **`mix.exs`** — `version: "0.1.0"`, `elixir: "~> 1.18"` floor intact; CLAUDE.md
  toolchain note (Elixir 1.20.0/OTP29) consistent with 344348c/0413ae6.

## Found & fixed (2 findings, docs-only)

1. **CHANGELOG gap — Task 207 had no entry.** The configurable default-dispatch-agent
   feature (`{:dispatch, :default_agent}` config defaulting to `:codex`,
   `Config.dispatch_agents/0`, the `CapabilityScore` fallback, the Settings select)
   shipped (3c22a81) with no CHANGELOG touch. Added an Unreleased § Added entry.
2. **Stale CHANGELOG — Task 205 outcome not reflected.** The scrub entry still read
   "the other four adapters default to `[]` pending per-CLI verification (Task 205)",
   but Task 205 landed (0fdaacc) declaring `CURSOR_API_KEY` (Cursor) and `XAI_API_KEY`
   (Grok), with Antigravity and Pi intentionally declaring none. Updated the entry to
   the shipped reality.

Both fixes are CHANGELOG-only — no code touched, so no project checks run (the merged
code was already reviewer-gated per task).

## Reviewer false-rejection note

No reviewer rejections recorded for this project in the landed range. N/A.

## Verdict

Clean range modulo two documentation hygiene gaps, both fixed forward. No code,
test, or convention defects. No reverts.
