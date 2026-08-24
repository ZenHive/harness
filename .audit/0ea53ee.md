# Audit — 0ea53ee (range 2ee058b..0ea53ee)

Post-merge hygiene pass over 16 landed commits. Most of the range is
roadmap filing / status writeback. Code-bearing deliveries:

| SHA | Subject | Kind |
|---|---|---|
| 0ea53ee | file tasks 400 (TargetSync self-host guard) and 401 (restore green mix ci) | roadmap |
| ae59c05 | task 397 -> done | roadmap |
| 6596acd | task 397 consume harness_agent_adapter, delete in-repo AgentAdapter | code (extraction) |
| 91e64a8 | file task 399 (question.json hold/steer) | roadmap |
| cb52f31 | task 396 done; retarget 397 to kept namespace | roadmap |
| c3389ad | bandit 1.12.5, descripex 0.13.0, phoenix 1.8.12, phoenix_live_view 1.2.10 | deps |
| cd50f28 | adjudicated deployment-hardware decision | docs |
| fbee21b | descripex 0.12.1, req 0.7.3, tidewave 0.9.0 | deps |
| e2f02e2 | file tasks 396-398 | roadmap |
| 3959af2 | cross-family reviewing is orchestrator doctrine | docs |
| 5e0a72b | file dsh-derived tasks 392-395 | roadmap |
| 574ad1e | task 391 — roadmap-mark_* MCP tools declare no parameters | roadmap |
| 335b5b8 | watch origin for landing commits instead of dispatch-await | docs |
| 722f97d | accept cursor-branded model ids (cursor-grok-4.6-*) | code (then extracted) |
| 362856b | retire cursor composer-2.5 pin | docs |
| 2ee058b | align cron scheduling and close architect QA findings | code (fix) |

## What I checked

- **Task 397 extraction** — `mix.exs` takes the git dep; in-repo `lib/harness/agent_adapter*` and the moved tests are gone. Call sites still compile against `Harness.AgentAdapter.*`. Test doubles were renamed to `Harness.AgentAdapter.Testing.*`. Agent timeouts live under `config :harness_agent_adapter, :run`; `Config` still exposes `{:run, :total_timeout}` / `:idle_timeout` as nil-default UI overrides that Run forwards as Driver opts. The extracted package (lock SHA `d869805c`) already carries the 722f97d `cursor-` family prefix, so deleting the in-repo adapter did not drop `cursor-grok-4.6-high` validation.
- **CHANGELOG gaps** — 397, the cron-timezone fix, and the bandit 1.12.5 security bump had no `[Unreleased]` entries.
- **Stale operator-facing copy after 362856b** — `dispatch-compare`'s `api()` example still pinned `composer-2.5` / `grok-4.5`. CLAUDE.md / AGENTS.md / the driver skill still named `Harness.AgentAdapter.ConformanceCase`, which now lives at `Harness.AgentAdapter.Testing.ConformanceCase` in the package.
- **No leftover `IO.inspect`/`dbg`/bare `TODO` in the code diffs.** Task 398's `files_to_modify` still names the deleted in-repo `rules_injection.ex`; that is 398's own implementation location (work now belongs in the package), not a separate discovery. Tasks 400 and 401 already cover the TargetSync self-host crash and the pre-existing red `mix ci`.
- No false-rejection note: the supplied task-208 coverage reject is not in this range.

## Findings & fixes

| # | Finding | Severity | Action |
|---|---|---|---|
| 1 | Task 397 extraction missing from CHANGELOG | minor | Added `[Unreleased]` Changed entry |
| 2 | Cron timezone / tzdata fix missing from CHANGELOG | minor | Added `[Unreleased]` Fixed entry |
| 3 | bandit 1.12.5 (HIGH CVE fix) missing from CHANGELOG | minor | Added `[Unreleased]` Security entry |
| 4 | `dispatch-compare` still exemplified retired `composer-2.5` / `grok-4.5` pins | minor | Updated the `api()` example to `grok-4.6` / `cursor-grok-4.6-high` |
| 5 | Docs still named the pre-extraction `ConformanceCase` module | minor | CLAUDE.md / AGENTS.md / driver skill now point at the package + `Testing.ConformanceCase` |

## Reviewer-rejection cross-reference

The recent rejection in the feedback loop was **task 208**
(`run-1780839809032-86dd1f20`, `mix precommit.full` coverage 79.47% <
80.0%). It is **not** in this landed range — no false-rejection note
applies. Task 397 landed as a reviewer-approved delivery and the
committed diff matches its acceptance criteria (namespace kept, in-repo
subsystem deleted, timeouts mirrored onto the package key).

## Discoveries filed

None. Tasks 400 and 401 were filed in this range (TargetSync self-host
guard; restore green `mix ci`). Task 398's stale `files_to_modify` is
the implementer's problem on that task, not a second filing.

## Cold check

Ran `mix deps.get` then `mix check.dispatch` in this intentionally
un-warmed worktree (log
`/var/folders/ht/838bqmdn3c1g6f336kw3vc440000gn/T/harness-check-dispatch.XXXXXX.log.nHgM4mS0NC`).
Format, compile `--warnings-as-errors`, Credo `--strict`, Doctor, and
Sobelow all passed (`CHECK_DISPATCH_EXIT=0`). Result recorded in
`.harness/audit.json` `cold_check`.
