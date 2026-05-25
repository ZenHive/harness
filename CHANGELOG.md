# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `Harness.Worktree` — per-run git worktree lifecycle: `create/2` carves an
  isolated working directory and `harness/<id>` branch out of a target repo so
  concurrent runs never collide; `commit/2` captures the agent's work as a
  commit on that branch; `finish/3` makes the keep-or-teardown decision
  (tear down on success, retain on failure for inspection — configurable);
  `remove/1` is the unconditional teardown. Teardown removes only the working
  directory — the branch and its commits are the run's deliverable.
- `Harness.Worktree.Sweeper` — boot-time orphan reaper. A run that crashes
  before `finish/3` leaves its worktree behind; the sweeper runs once at
  application start, self-discovers parent repos from leftover worktrees, and
  reaps every orphan that is not a deliberately-retained failure.
- Worktree root is configurable via `:harness, :worktree` (`base_dir`,
  `retain_on_failure`, `sweep_on_boot`) and the `HARNESS_WORKTREE_ROOT` env var.
- `Harness.Roadmap` — ingests a task from an rmap roadmap (by id or the next
  pending one) and renders it as a ready-to-run agent prompt. Shells out to the
  `rmap` CLI (`show` / `next` / `delegate`) rather than parsing the roadmap
  itself, keeping rmap the single source of truth. The input half of the loop.
- `Harness.AgentAdapter` behaviour — the contract every headless coding-agent
  adapter implements: a capability declaration, headless-command construction,
  raw-output capture with termination detection, and cancellation. Raw
  passthrough only — no normalized event model. Agents are spawned over an OTP
  port through a `/bin/sh` wrapper that hands them a stdin already at EOF, so a
  headless CLI never stalls peeking for piped input.
- `Harness.AgentAdapter.Claude` — the first concrete adapter: drives Claude Code
  headlessly (`claude -p`, raw `stream-json` output, `--permission-mode
  bypassPermissions` for unattended runs, `--continue` session resume against
  the per-job worktree).
- `Harness.AgentAdapter.Codex` — the second concrete adapter, and the first
  proof the `AgentAdapter` contract is not Claude-shaped: drives Codex
  headlessly (`codex exec` raw `--json` JSONL,
  `--dangerously-bypass-approvals-and-sandbox` for unattended runs,
  `exec resume --last` session resume against the per-job worktree). Codex's
  invocation is structurally unlike Claude's — `exec` is a subcommand and
  resuming swaps in `exec resume` rather than adding a flag — yet it was built
  against the unchanged behaviour and passes the conformance suite unchanged,
  so no abstraction leak was surfaced.
- `Harness.AgentAdapter.Cursor` — the Cursor adapter: drives `cursor-agent -p`
  headlessly (raw `stream-json` output, `--force --trust` for unattended runs on
  a fresh worktree, `--continue` session resume). Passes the conformance suite
  unchanged — the contract held against a third agent with no behaviour leak.
- `Harness.AgentAdapter.Grok` — the Grok Build adapter: drives Grok headlessly
  (`grok -p`, raw `streaming-json` output, `--permission-mode bypassPermissions`
  for unattended runs, `--continue` session resume against the per-job
  worktree). Grok's headless-only extras (`--best-of-n`, `--check`, worktree
  flags) are deferred to the capability registry, not the core behaviour.
  Passes the conformance suite unchanged.
- `Harness.AgentAdapter.Antigravity` — the Antigravity CLI adapter: drives `agy`
  headlessly (`agy -p`, raw output captured verbatim,
  `--dangerously-skip-permissions` for unattended runs, `--continue` session
  resume). Passes the conformance suite unchanged.
- `Harness.AgentAdapter.Driver` — the generic run driver: spawns any adapter,
  captures raw output, and enforces two timeout guards — a total-run budget and
  an idle window reset on every output chunk — so a runaway or wedged run is
  killed. Termination is derived from the process closing or a deadline, never
  the exit code. Returns a `Harness.AgentAdapter.Outcome`; timeouts configurable
  via `:harness, :run`. An `:on_spawn` hook hands the run handle to the caller
  the moment the agent spawns, so a wrapping process can cancel it mid-run.
- `Harness.AgentAdapter.OSProcess` — shared port / OS-process lifecycle helper
  (os-pid lookup, idempotent close, mailbox drain, kill) every adapter reuses.
- `Harness.AgentAdapter.ConformanceCase` — the reusable conformance suite every
  adapter must pass, parameterized by adapter module: it pins the contract for
  invocation, verbatim raw-output capture, termination detection, timeout, and
  adapter-level cancellation. The contract checks are agent-free (synthesized
  port messages, a `/bin/sleep` stand-in); one `:integration`-tagged test drives
  the real agent end to end. The gate Codex and every later adapter (Cursor,
  Grok, Antigravity) are held to — a leak it catches is fixed in the behaviour,
  never patched around in the adapter. Run against every adapter — Claude,
  Codex, Cursor, Grok, Antigravity — and `Harness.FakeAdapter`.
- `Harness.Verification` — the run grader: runs a target project's check stack
  against a worktree and aggregates the results into a `Verdict`. This is how
  harness decides "did the job succeed?" objectively, never from the agent's
  self-reported exit code. Ships an Elixir preset (`mix test.json`,
  `mix dialyzer.json`, credo, doctor, sobelow); the stack is configurable via
  `:harness, :verification`. Each check is spawned over an OTP port with a
  per-check timeout, so a hung check is killed rather than wedging the run. The
  verification half of the loop.
- `Harness.Run` — the supervised run lifecycle: a `:gen_statem` that owns one
  job end to end, moving through `dispatched → running → committing → verifying
  → {done | failed}`. It carves the isolated worktree, dispatches the agent,
  waits for termination, commits the agent's work to the run branch, runs the
  verification stack, and settles on a verdict — the single-agent core loop
  working end to end. A run that produced no diff settles `:no_changes`. Each
  step runs in a monitored task so a crashing step never crashes the run; a
  per-run lifetime budget and `cancel/1` both abort cleanly, SIGKILLing the
  agent; `status/1` exposes live state. A run is graded by the verification
  stack alone, never by the agent's exit code — a run whose agent timed out is
  still verified.
- `Harness.Run.Supervisor` — the `:one_for_one` `DynamicSupervisor` each
  `Harness.Run` starts under as a `:temporary` child, so one run crashing is
  isolated from its siblings and a failed run is never restarted. `start_run/4`
  is the entry point; runs are looked up by id through a `Registry`.
- Autonomous repair loop — a red verification verdict is no longer terminal.
  While repair attempts remain, `Harness.Run` resumes the **same** agent with a
  prompt (`Harness.Run.RepairPrompt`) carrying the failing checks' output,
  re-commits, and re-grades. The objective check stack stays the grader, so the
  agent is repairing rather than self-grading. The loop stops on green, at the
  attempt cap, or on a non-red terminal failure of an attempt — a quota-starved
  agent that produces no diff settles `:no_changes` instead of burning the
  remaining attempts. `repair_attempts` on `Harness.Run.Result` and
  `Harness.Run.Status` reports how many attempts a run made.
- `Harness.Batch` — the batch layer: fans a set of tasks out across supervised
  `Harness.Run` children under a configurable concurrency cap, tolerates partial
  failure (one red or crashed run never aborts the batch), and collects one
  `Harness.Run.Result` per task — in input order — into a `Harness.Batch.Result`.
  A batch is typically an `rmap` bundle or `rmap next-bundle` result.
- `Harness.Run.RetryPolicy` + `Harness.Run.FailureClass` — failure-classified
  retry: a failed run is classified `:transient` (a process crash or flaky
  check — retried with capped exponential backoff), `:quota_exhausted` (a
  subscription agent at its cap — stops retrying that agent at once and marks it
  for fail-over, since the reset window is hours, not a backoff timescale), or
  `:terminal` (a genuine red verdict — never retried). The policy is available
  as a standalone helper (`RetryPolicy.run/2`) and configurable via
  `:harness, :retry_policy`. Wired into `Harness.Batch` (Task 28, below).
- Run lifecycle timeouts and the repair-attempt cap are configurable via
  `:harness, :run` (`lifetime_timeout`, `terminal_linger`,
  `max_repair_attempts`) alongside the existing agent `total_timeout` /
  `idle_timeout`.
- Caller-controlled agent environment — `Harness.AgentAdapter.Invocation` carries
  an `env` map threaded through every adapter's `build_command/1` into the port
  spawn: `%{"KEY" => "value"}` sets a variable, `%{"KEY" => false}` scrubs an
  inherited one (e.g. removing `ANTHROPIC_API_KEY` so `claude` falls back to its
  subscription OAuth). Passed per run via the `:env` opt to `start_run/4`; the
  orchestrator BEAM's own environment is never mutated. The conformance suite
  gates both injection and scrubbing on every adapter.
- `Harness.AgentRules` + `priv/agent_rules/canonical.md` — the canonical,
  harness-owned rule set every dispatched agent receives. A curated filterable
  subset: verification gates (coverage thresholds, dialyzer-zero,
  credo-strict) are deliberately excluded because the verification runner
  enforces them, not prose the agent is trusted to honour.
- `Harness.AgentAdapter.RulesInjection` — per-adapter rule-set injection
  threaded through every adapter's `build_command/1`. Claude uses
  `--append-system-prompt-file`; Codex and Cursor render an ephemeral rule
  file into the run worktree; Grok and Antigravity prompt-prepend (neither
  exposes a system-prompt flag or a native rule file). Two different agents
  dispatched by harness now receive the same canonical rules without any
  hand-maintained per-repo file.
- `Harness.AgentRegistry` — declarative per-adapter capability listing plus
  availability state. `Harness.Batch` and `Harness.Run.Supervisor` gain a
  capability check before dispatch: a run requesting an unsupported
  capability is rejected up front, never mid-run. A quota-exhausted agent is
  marked unavailable and the batch routes its task to another capable
  adapter with headroom; fail-over routing is observable via
  `Harness.Batch.Result` events.
- `Harness.StatusView` + `mix harness.status` — a human-readable fleet view
  (`Harness.StatusView`) that aggregates live `Harness.Run.Status` snapshots
  from `Harness.Run.Supervisor` and unavailable agents from
  `Harness.AgentRegistry`, classifying runs into `IN FLIGHT` / `REPAIRING` /
  `GREEN` / `RED` with the failure reason for red runs and the attempt count
  for runs in repair. `Harness.AgentRegistry.list_unavailable/0` exposes the
  unavailable adapter list, and `Harness.Run.Status` gains a `:reason` field
  so the view can surface why a run settled. The Mix task is a thin
  IO.puts wrapper around `StatusView.snapshot/0` and `StatusView.render/1`.
- `Harness.ResultStore` + `Harness.ResultStore.File` — pluggable result-store
  boundary. `Harness.ResultStore` declares the `record_run/2`, `save_batch/2`,
  `load_batch/2`, `list_run_records/2` callbacks; `Harness.ResultStore.File`
  is the file-backed default, persisting Erlang external terms under a
  configurable root (`~/.harness/results` by default). Persistence is
  best-effort: store errors are logged via `Logger.warning/1` and never crash
  a run or a batch. Configured via `config :harness, :result_store` as
  `module()`, `{module(), keyword()}`, `nil`, or `false` (the last two
  disable persistence).
- `Harness.Run.LogRecord` — structured, queryable per-run-attempt record
  (`agent`, `adapter`, `verdict`, `reason`, `duration_ms`, `repair_attempts`,
  `first_attempt_failed_check_count`, `agent_diff_size`, `failure_cause`,
  `agent_outcome_kind`, `agent_exit_status`, `agent_output`). Emitted by
  `Harness.Run` when a run settles and by `Harness.Batch` when a run crashes
  before delivering a result. Failure causes — including the failing-check
  summary — are reconstructable from the record alone, no live run process
  needed.
- `Harness.Batch.Result` gains a `:batch_id` field. `Harness.Batch.run/4`
  generates one when the caller does not supply it, threads it through
  `Harness.Run`'s state, and persists the aggregate `BatchResult` via
  `ResultStore.save_batch/2` so batches survive process exit. Reloadable
  via `Harness.ResultStore.load_batch/2`.
- `Harness.Run.Result` gains `:first_attempt_failed_check_count` and
  `:agent_diff_size`. The diff size is measured by `Harness.Worktree.diff_size/1`
  (a `git add -A` + `git diff --cached --numstat HEAD` pair) before commit,
  so the count matches what `commit/2` captures.
- `Harness.AuditReview` — HIGH-tier second-grader dispatch wrapper for the
  codified `staged-review:audit-review` skill. `grade_fix/1` dispatches the
  opposite-agent grader (`:claude ↔ :codex` auto-pair; explicit `:grader`
  overrides) via `Harness.AgentAdapter.Driver.run/3` directly — bypassing
  `Harness.Run` and the verification stack on purpose (the grader's *text* IS
  the verdict, not a green/red check). Parses a `<<<VERDICT:APPROVE|REJECT>>>`
  sentinel from the raw transcript with last-match-wins, returning
  `{:ok, %{verdict, outcome, grader}}` for any dispatch that spawned. Synchronous;
  one-shot and read-only. (Task 58)

### Fixed

- `Harness.Batch` no longer crashes with a `MatchError` when every capable
  adapter has been marked unavailable (typically by quota fail-over) mid-batch.
  Queued items that have not yet been dispatched now settle as `:failed`
  `Harness.Run.Result`s with reason `{:no_available_agent, reason}` and emit
  a per-item `{:no_available_agent, task_id, reason}` event on the batch's
  event log instead of orphaning active runs. The reason type on
  `Harness.Run.Result` widens to include `{:no_available_agent, term()}` for
  this terminal state.
- `Harness.Worktree.commit/2` (and `diff_size/1`) no longer commits the harness-injected agent rules into the run branch. `Harness.AgentRules.cleanup_injected_rules/1` removes the Claude / Cursor rule files outright and strips only the harness-injected block from Codex's `AGENTS.md`, preserving legitimate agent edits below the block. (Task 36)
- `Harness.Worktree.commit/2` now asserts the worktree's HEAD still points at its own `harness/<id>` branch (via `rev-parse` + `symbolic-ref` check) before staging. An agent that ran `git switch` or detached HEAD inside the worktree would previously land the commit off-branch and have its deliverable lost at teardown; the run now settles `{:commit_failed, {:head_moved, where}}` cleanly instead. (Task 30)
- `Harness.Batch`'s internal `fill_slots` loop no longer crashes the whole batch when `Harness.Run.Supervisor.start_run/4` returns an error tuple (e.g. duplicate `run_id`, `DynamicSupervisor.start_child/2` failure after adapter selection). The failed item settles `:failed` with the start_run error reason; sibling items in the batch continue to run. (Task 35)
- `Harness.Run.FailureClass.classify/2` correctly classifies quota exhaustion *before* a repair-loop resume can fire. The repair loop previously treated a quota-classified failure as repairable, burning a repair attempt on an agent that physically cannot make progress; the classifier now short-circuits with `:quota_exhausted` so the run settles immediately and routes to fail-over via `Harness.AgentRegistry`. (Task 37)
- `Harness.Run` releases its batch concurrency slot the moment the result is delivered to the subscriber, not after `terminal_linger` expires. Status remains observable through the linger window for late `status/1` callers, but the slot is free for the next item — fixes a multi-second stall on every batch under the previous behaviour. (Task 38)
- `Harness.Run` force-settles `:failed` with reason `:timed_out` when the lifetime budget elapses, even if the agent's `{:run_handle, _}` message never arrived. Previously a hanging `build_command/1` could wedge the run indefinitely; the lifetime timer now fires unconditionally and `force_settle_lifetime/1` replies to any deferred cancel caller before transitioning. (Task 29)
- `Harness.Verification` preset tightened to silence Round-4 false positives without weakening the gate: `sobelow_skip ["CI.System"]` annotations cover the `System.cmd("mix", ...)` invocation in `BaselineFilter.Credo` (literal-only argv, never shell-interpolated), and `:jason` is added to `:dialyzer.plt_add_apps` so dialyzer recognises the new `Jason.decode/1` call site under `plt_add_deps: :apps_direct`. (closeout of Tasks 36 + 43)
- Initial OTP application scaffold with a supervision tree (`Harness.Application`).
- Standard Elixir dev/test tooling stack: Styler (formatter plugin), Credo,
  Dialyxir, Doctor, Sobelow, `ex_unit_json`, `dialyzer_json`, `ex_dna`, `ex_ast`,
  and Reach + Boxart for OTP analysis.
- `descripex` as the agent-facing API dependency.
- `tidewave` + `bandit` for the dev MCP/HTTP surface (Tidewave on port 4016).
- `cli/0` preferred-env wiring for `mix test.json` / `mix dialyzer.json`.
- Dialyzer configured with `plt_add_deps: :apps_direct`; PLTs under `priv/plts/`.
- Project configs: `.doctor.exs`, `.dialyzer_ignore.exs`, `.reach.exs`, `.mcp.json`.
- `Harness.AgentAdapter` — hoisted the byte-identical `classify_message/2`, `terminate/1`, and `--model` argv helper into the behaviour via `use Harness.AgentAdapter` + `defoverridable` (with top-level default providers). A new adapter now implements only `capabilities/0` + `build_command/1` and passes the conformance suite; all 6 existing adapters were updated (duplication removed) and continue to pass unchanged. Added `model_args/1` public helper. (Task 27)
- `Harness.Batch` now dispatches every Run start through `Harness.Run.RetryPolicy.run/2`, so the orchestrator consumes failure classifications natively: transient errors (worktree-create, lock contention) are retried up to the policy's cap, quota classifications halt fan-out for the affected adapter, and exhausted-retry surrender settles the slot as `:failed` with the last classification. The wired-in policy is exposed via `Batch.start_link/1` opts. (Task 28)
- `Harness.Verification.Check` gains an optional `post_process` hook (`{module, function}`) re-graded against the per-run baseline. `Harness.Verification.BaselineFilter.Credo` is the first hook: it runs `git diff --name-only base..HEAD` to scope inherited debt out of credo's `TagTODO` findings, so pre-existing `TODO:` comments no longer red the verification stack on otherwise-clean dispatched work. `Harness.Worktree` now captures `:base_sha` at carve-out (stable for the worktree's lifetime) and `Harness.Verification.run/2` threads `:base_ref` through `post_process_opts`. (Task 43)
- Baseline `.gitignore`, `README.md`, and this changelog.
