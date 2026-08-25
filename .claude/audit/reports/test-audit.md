# Test Health Audit — harness

**Method note (limits this report's confidence):** this subagent has no Bash
tool access, so the requested `mix test.json --cover` pass could not be run.
All findings below are from static analysis (Read/Grep/Glob) over `test/` and
`lib/harness/`, not from measured coverage percentages. Treat coverage-gap
claims as directional (file-existence / describe-block-density proxies), not
as verified `<80%`/`<95%` numbers. Re-run with a Bash-capable session for
exact percentages.

## Findings

### High

- **`lib/harness/git/target_sync.ex` (self-host land-safety guard, 154 lines) has no dedicated test file** — its 7 `describe`/`test` blocks live folded into `test/harness/git_test.exs:30-135` instead of a `target_sync_test.exs`. Coverage itself looks good (self-host, symlink-alias self-host, dirty tree, non-ff, drift message, off-target ff, on-target clean ff are all exercised — no gap in behavior), but for a module CLAUDE.md calls out by name as the guard against a self-land mutating the running node's own checkout, its critical-tier (≥95%) status should be verified with an actual `--cover` run, not inferred from file layout. Flag for a coverage-pass confirmation, not a rewrite.

### Medium

- **`test/harness/chat/session_test.exs:373,398,404` — fixed `Process.sleep` waiting on a timer, not a poll-until-condition loop.** These three sleeps wait for `idle_timeout` (100ms / 50ms) to fire and then assert the session process is gone (`refute Supervisor.whereis(id)`) or still alive. Unlike the poll-loop helpers in `test/support/run_case.ex` (which retry with a bounded budget — the project's accepted alternative to `Process.sleep`), this pattern asserts a negative/positive state after one fixed wait with only a 1.5–2x margin over the timer. Under CI load (scheduler contention, GC pause) this is flaky-risk: the process may not have been reaped yet at the 150-200ms mark even though it will be shortly after. Fix: poll for `refute Supervisor.whereis(id)` with a bounded retry (mirroring `await_held`/`wait_until_running` in `run_case.ex`) instead of a single fixed sleep, or use `Process.monitor(pid)` + `assert_receive {:DOWN, ...}` to detect the reap deterministically.

- **No dedicated `test/harness/run_test.exs` for the core `Harness.Run` gen_statem (`lib/harness/run.ex`, 549 lines, 8-state machine: `:dispatched → :running → :committing → :recovering → :reviewing → :held → :done/:failed`).** Coverage is spread across ~20 scenario files under `test/harness/run/*_test.exs` (checkout_pollution_recovery, discernment_stakes_gate, external_cancellation, failure_isolation, implementer_idle_timeout, operator_recovery, per_run_timeout, reviewer_fixes, reviewer_idle_timeout, reviewer_timeout_rotation, reviewing_watchdog, state_callback_fallbacks, transcript_events, transcript, worktree_isolation, memory_guard, memory_watchdog, code_reload_crash, observable_state, retry_policy, settled_notification, log_record). This is a defensible scenario-driven organization (each file names a specific failure/recovery path) rather than a gap per se, but there is no single file that enumerates all 8 states × all documented failure reasons as a matrix, making it hard to audit "is every transition covered" without reading ~20 files. Recommend a `test/harness/run/state_matrix_test.exs` (or a comment block in one canonical file) that cross-references states/reasons to the scenario file that covers each, so a missing transition is discoverable by inspection rather than by reading every file.

### Low

- **`Process.sleep` count (31 call sites across `test/`) is higher than the project's "NO PROCESS.SLEEP" rule implies at first grep**, but on inspection nearly all are legitimate: bounded poll-until-condition helpers in `test/support/run_case.ex` (`await_held`, `wait_until_running`, `await_pid_file`, `await_agent_os_pid` — all with tries-based flunk fallback, the accepted alternative per `critical-rules.md`), deliberate scheduler-yield race fuzzing (`test/harness/batch_test.exs:481`, `Process.sleep(0)` in a 100-iteration loop racing `AgentRegistry.mark_unavailable`), or simulated lock-release delays paired with `assert_receive` (`test/harness/worktree_test.exs:124-137`). Only the 3 chat/session_test.exs sites above are true anti-pattern uses; no action needed on the rest, but worth a comment noting the intentional exception at the batch_test.exs:481 sleep(0), since a future reader may "fix" it into a proper poll loop and change the race-fuzz semantics.

## Clean Areas (one line each, no deep issues found)

- Mox / mocking: not used at all — architecturally correct for this codebase (agents are external Ports with raw-passthrough capture, not mockable boundaries); no internal-module or DB mocking found.
- `async: false` usage (88 files) is consistently justified with an inline comment naming the shared/global state (AgentRegistry, Application env, Postgres, ProjectRegistry) — no unexplained or seemingly-unnecessary `async: false` found in the sampled files.
- No empty test bodies, no bare `{:error, _} -> :ok`/`:true` catch-alls, no `assert true`/`assert !` anti-patterns found anywhere in `test/`.
- No unsupervised named `GenServer.start(name: ...)` in tests found — process lifecycle in tests goes through supervision/`start_supervised!` patterns.
- All 6 `Oban.Worker` modules (`lander/worker.ex`, `run/worker.ex`, `audit/worker.ex`, `cron/roadmap_poller.ex`, `cron/suite_health_poller.ex`, `cron/dep_freshness_poller.ex`) have dedicated test files exercising `perform/1` (roadmap_poller_test.exs alone has 24 `perform`-related call sites).
- All 7 dashboard LiveView pages (`roadmap_live`, `kpi_live`, `chat_live`, `compare_live`, `suite_health_live`, `dep_freshness_live`, `settings_live`) have corresponding `*_live_test.exs` / mount test files.
- `Harness.Lander` (`lib/harness/lander.ex`, 793 lines) has extremely thorough scenario coverage in `lander_test.exs` — ff-path, rebase-path, non-ff push race, conflict/resolver path (including the "resolver leaves markers → never lands" negative case), post-merge audit trigger enqueue, and the `enqueue/1`/`landing_args/2` re-land recovery primitives are all exercised.
- `dispatch.ex` (1721 lines) has 111 `describe`/`test` blocks in `dispatch_test.exs` alone — no evidence of shallow coverage.
- `System.unique_integer` used pervasively (185 call sites, 67 files) for test-data uniqueness — low order-dependence / cross-test collision risk.
- No hidden-failure `rescue`/`catch` patterns found in test files.
- `test/support/` fixture modules (`git_fixture.ex`, `project_fixture.ex`, `process_fixture.ex`, `github_fixture.ex`, `chat/fun_backend.ex`) are behaviour-implementing test doubles appropriate to the AgentAdapter architecture, not Ecto-schema factories — `build/insert` factory conventions don't apply here (no ExMachina in the dep stack), so that checklist item is not applicable to this codebase.

## Test-Health Score: 82/100

Justification: no genuine hidden-failure or dead-test anti-patterns found anywhere in a 184-file suite, and the three highest-risk subsystems (lander, dispatch, target_sync self-host guard) show unusually thorough scenario coverage including explicit negative/failure paths — but the score is capped below "clean" because (a) this audit could not run the requested `--cover` pass to verify the ≥80%/≥95% tier claims quantitatively, so critical-module coverage is asserted from proxy evidence rather than measured, and (b) three real fixed-`Process.sleep`-as-synchronization sites exist in `chat/session_test.exs` against a project rule that explicitly forbids the pattern.
