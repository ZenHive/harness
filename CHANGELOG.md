# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **Cursor token usage now parsed — the KPI page no longer shows blank tokens
  for cursor-dispatched runs.** `Harness.TokenUsage.parse(:cursor, …)` routed
  cursor through the Anthropic stream parser, which reads snake_case
  `input_tokens`; cursor actually reports cumulative usage on its terminal
  `result` event with **camelCase** keys (`inputTokens` / `outputTokens` /
  `cacheReadTokens` / `cacheWriteTokens`), so every cursor run parsed to all-`nil`
  (16 stored records measured nothing). Added a dedicated `parse_cursor/1` +
  `from_cursor_usage/1` reading the real shape; the stale "cursor mirrors
  Anthropic" test (which fed snake_case and so never caught this) is replaced
  with a real-cursor-shaped fixture. Found dogfooding non-default agents. (Grok
  is *not* affected: its `end` event can carry `usage` and `parse_grok/1` already
  extracts it defensively, but it isn't emitted every run/release — both captured
  grok runs' `end` events had no `usage` key, so all-`nil` is correct-when-absent.
  Antigravity is plain text with no usage. Surfacing all-`nil` as "—/not reported"
  rather than a misleading 0 on the KPI page is a display follow-up, not a parser bug.)

- **MCP tool names now use "-" (not "__") as the group/action delimiter.** Descripex
  emits `<group>__<action>` (e.g. `dispatch__task`); when MCP clients (grok, others)
  qualify as `<server>__<tool>`, this produced `harness__dispatch__task` (two "__"),
  causing "Skipping MCP tool" rejects for the entire harness surface. The fix is
  centralized in `Harness.Manifest` (the single source of truth for both the MCP
  server and `Harness.Chat.Tools`): post-process Descripex output, expose
  `tool_name_delimiter/0`, update the two reverse-lookup splits. All 35 tool names,
  docstrings, and tests updated at the convention source. Grok-style qualified names
  now contain exactly one "__". Added test asserting the invariant. Task 135.
- **The cron poller no longer re-dispatches completed-but-unlanded tasks every
  tick — the run lifecycle now claims a dispatched task `in_progress` on start.**
  Under `landing_policy: :manual`, a run could finish green yet stay unlanded, so
  the task remained `pending` and the next tick re-dispatched the same green work
  forever (Oban `{project, item}` uniqueness only dedups *in-flight*, not
  completed-then-pending). `Harness.Run.Worker` now best-effort claims the task
  `in_progress` before `start_run` (a failed writeback logs and continues, never
  fails the run) via the new `Harness.Roadmap.mark_in_progress/2`; a green-unlanded
  run *stays* `in_progress` (only an explicit land moves it to `done`), while a
  terminal failure reverts to `pending` (`Roadmap.mark_pending/2`, not `blocked`)
  so a later tick retries — transient failures snooze without reverting. Writeback
  owner is the run lifecycle, not the poller. Delivered by grok via harness
  dogfooding (run `run-1780277844276-9fec2836`, verdict `pass`), Task 131.
- **Grok (and any token-streamed) chain-of-thought now renders as one collapsed
  reasoning card instead of a wall of empty `THOUGHT` rows.** Grok streams
  reasoning token-by-token — one `{:system, kind: :thought}` event per token —
  and the run-detail transcript reducer emitted a separate block per event while
  the `eyebrow/1` renderer deliberately drops the `data` payload. A single thought
  therefore rendered as ~150 bare "THOUGHT" labels with the text discarded
  (the raw stream had every fragment; the parsed view threw it all away). The
  reducer now folds consecutive `:thought` events into one `:thought` block
  (mirroring the `:assistant_text` accumulator), rendered as a collapsed
  `<details>` "reasoning" card carrying the concatenated text — dim and secondary
  to assistant output. Found dogfooding a grok dispatch of Task 131.
- **Per-project Oban dispatch + landing queues now actually start at boot, so
  enqueued runs no longer sit `available` forever.** `Harness.Oban.ensure_project_queue/1`
  and `queue_headroom?/1` guarded queue starts on `Process.whereis(Harness.Oban)`,
  which is always `nil` — Oban registers its instance through `Oban.Registry`
  (a `{:via, ...}` name), never as a globally named process. The guard therefore
  short-circuited every start: config-registered projects' queues never left
  `[:cron]` at boot, and cron-enqueued `Run.Worker` jobs had no producer to run
  them (observed 2026-05-31: 5 jobs stuck `available` on `project_harness` until
  a manual `Oban.start_queue`). Both guards now use `Oban.whereis/1`, the
  registry-aware liveness check. Autonomous dispatch was inert before this fix
  (Task 133).
- **Autonomous cron polling no longer dispatches `handbuild` tasks headless, and
  now dispatches the whole parallel-safe batch per tick instead of one task.**
  `Harness.Cron.RoadmapPoller` selected work via `Harness.Roadmap.ingest(:next)`,
  which shells `rmap next` — a surface with no `--dispatchable`/negative-marker
  filter, so it returned `handbuild`-marked UI tasks that then idle-timed-out
  under headless dispatch (observed: task 127, a LiveView, dispatched to Claude).
  It also enqueued only the single `:next` task per tick. The poller now selects
  via new `Harness.Roadmap.ready/1` (`rmap ready --dispatchable --fields id,model,markers`),
  which excludes `handbuild` and returns the full deps-done set, and enqueues one
  `Run.Worker` per task — Oban's per-project queue caps concurrency at the
  project's `concurrency_cap` (the harness self-project now sets `concurrency_cap: 10`).
  Inserts are unique over `{project_name, item_id}` across non-terminal states, so
  a later tick won't re-enqueue an in-flight task. Each task routes to its agent
  via the `model` field (the harness roadmap's convention), then `cx`/`csr`
  markers, else `:claude`; a task whose agent is operator-disabled or
  quota-unavailable is skipped via `AgentRegistry.select/2`.
- **Run records (and chat sessions) written by a prior build are no longer
  silently dropped on read.** `Harness.ResultStore.File` and `Harness.Chat.Store`
  decoded their persisted `.term` files with `:erlang.binary_to_term(body, [:safe])`;
  `[:safe]` rejects any term referencing an atom not currently interned in the
  running BEAM, so a record/session whose `reason`/`agent`/`adapter` atom came from
  an older build failed to decode and vanished from the dashboard run history, the
  per-agent KPI ledger, and `load_batch/2` (observed: 30 of 45 real run records
  invisible). These are harness-owned files written by harness's own
  `term_to_binary`, not untrusted input, so `[:safe]` guarded a non-existent threat
  at the cost of dropping valid data. Both now decode without `:safe`; the existing
  `rescue ArgumentError` still catches genuinely torn bytes.

### Added

- **`roadmap__ready` MCP/chat tool.** `Harness.Roadmap.ready/1` — the parallel-safe,
  headless-dispatchable task set the cron poller fans out (`rmap ready --dispatchable`,
  `handbuild` excluded; Task 129) — is now descripex-`api()`-annotated, so it surfaces
  as `roadmap__ready` on the `/harness/mcp` endpoint and the in-process chat tool
  dispatcher. An external orchestrator can read the fan-out-safe batch as structured
  data without shelling rmap.
- **Per-agent enable/disable from the Settings page.** An operator takes an agent
  out of dispatch rotation (a flaky CLI, an exhausted paid plan, a model under
  evaluation) with a toggle on `/harness/settings` — an **Agents** card listing all
  six adapters with an enabled/disabled pill and a "not installed" hint when the CLI
  binary is off PATH. A disabled agent is skipped by `Harness.AgentRegistry.select/2`
  (the universal dispatch gate, so runs, batches, and cron ticks all honour it),
  returning `:no_available_agent` when no enabled+capable adapter remains.
  Operator-disable is **persisted** (`~/.harness/agent_settings.term`, mirroring
  `Harness.Chat.Store` / `Harness.Cron.Settings`; disable with
  `config :harness, :agent_settings, false`) and seeded into app env on boot — a
  durable operator decision, deliberately distinct from the transient,
  clears-on-restart quota hint (`available?/1`) it composes with (`select/2` needs
  both enabled AND available). Agents default ON; disabling is opt-in. Flips are
  audited at info level naming the actor. New module `Harness.Agent.Settings`.
- **Runtime cron-autonomy toggles — master + per-project (Tasks 109/110).** A
  persisted, dashboard-driven kill-switch for autonomous roadmap polling. The
  master flag (the fleet-wide incident switch) and a per-project flag are flipped
  at runtime from a dedicated **Settings page** (`/harness/settings`, linked from
  the navbar) — toggle switches over the existing dark design system, with a
  resolved-status pill and an armed/dispatching/paused state per project — no
  config edit, no restart. Effective autonomy is `master AND project`: a project dispatches only
  when both are on, so a new project stays non-autonomous (flag defaults OFF)
  until an operator opts it in, and the master switch pauses the whole fleet at
  once. The panel shows the resolved poll status (`RoadmapPoller.status/0`) and
  warns when master is ON but no project is enabled (nothing would dispatch).
  Flips are audited (info-level log naming the actor) and persisted to a
  file-backed term store (`~/.harness/cron_settings.term`, mirroring
  `Harness.Chat.Store`; disable with `config :harness, :cron_settings, false`),
  so a choice survives a BEAM restart — seeded back into app env on boot before
  Oban starts. The `Oban.Plugins.Cron` entry now registers **unconditionally**
  (previously gated on the boot-time `enabled` flag): the tick is always
  scheduled, and whether it *dispatches* is the live gate inside
  `RoadmapPoller.perform/1` — without this, toggling autonomy on from a
  disabled-at-boot node had no scheduled tick to act on. Per-project skips log at
  info level (no longer a silent debug line). `%Harness.Project{}` and
  `ProjectRegistry.register/1` are unchanged — absence-means-off lives entirely
  in the settings store.
- **Per-agent KPI aggregation over run records (Task 114).** `Harness.AgentKPI`
  rolls a list of `%Harness.Run.LogRecord{}` (e.g. from
  `ResultStore.list_run_records/1`) up by `agent` into a per-agent ledger:
  `success_rate` (`:pass` / total), `first_attempt_pass_rate` (`:pass` with zero
  repairs), `duration_ms` median + p90 (nearest-rank), mean tokens
  (input/output/total), mean `repair_attempts`, and a `cost_to_green` composite
  (mean total tokens per `:pass` run, `nil` when an agent has no green runs). No
  new capture — every input field already exists on `LogRecord`. Pure functions
  only: the caller supplies the records, so the rollup is testable without I/O.
- **Per-agent KPI dashboard (`Harness.Dashboard.KPILive`, Task 115).** A
  sortable per-agent trust ledger at `/harness/kpi` (linked from the dashboard
  topbar) that renders `Harness.AgentKPI.aggregate/1` over every persisted run
  record: run count, success rate, first-attempt-pass rate, mean repair
  attempts, mean tokens, and cost-to-green — one row per agent, every column
  click-to-sort. An empty store renders an explicit "no run records yet" state
  rather than a table of zeros. Reads the store at mount and re-aggregates on
  each `:harness_run_settled` fleet event (the only event that mints a new
  record). Resolves the Task 81 (`CompareLive`) relationship as a **deliberate
  sibling**: this is the fleet-wide aggregate ledger, Task 81 is the
  per-comparison A/B surface — neither subsumes the other.
- **Run change-set view on the run-detail page.** Each run now shows what it
  changed: an in-flight run lists the files the agent is editing (from its
  transcript tool calls), and a settled run shows the actual git diff — file
  list with `+/−` proportion bars and a colorized unified patch — read on
  demand from the run's `harness/<run_id>` branch (no diff is persisted). A
  branch the autonomous lander has already merged/cleaned up degrades to a
  graceful note. (`Harness.RunDiff`, `Harness.Dashboard.Live`,
  `Harness.Dashboard.Components`.)
- **JSON-native dispatch observe / control / fan-out surface.** The flat
  `dispatch__*` MCP + chat tool family gained the run-lifecycle half a JSON
  orchestrator was missing: `dispatch__status` / `dispatch__transcript` /
  `dispatch__transcript_events` follow a live run by `run_id`, `dispatch__cancel`
  kills it (idempotent), `dispatch__bundle` fans the next session-sized roadmap
  bundle out as one Oban-backed job per task (delegatable adapters only —
  claude/codex/cursor), `dispatch__compare` runs one task A/B across N adapters
  in isolated worktrees, and `dispatch__verdict_detail(run_id)` reads a settled
  run's per-failed-check captured output. The first three are generated by a new
  `Harness.Dispatch.RunTool` compile-time DSL (`defrun_tool/1`, schema-validated
  via `nimble_options`) that wraps the uniform `{:ok, _} | {:error, :not_found}`
  `Harness.Run` observers. `%Harness.Run.LogRecord{}` now carries `check_output`
  — the bounded (16 KB tail-truncated per check, failing checks only) stdout+stderr
  of each failed check — so `dispatch__verdict_detail` works after the run process
  is gone.

- **Persisted run history in the dashboard (Task 105).** The dashboard index and
  drill-down previously read only live state, so every settled run vanished from
  view on a BEAM restart even though it persists durably as a
  `%Harness.Run.LogRecord{}` under `~/.harness/results`. The index now renders a
  "Run history" table merged from the `ResultStore` (deduped against live runs —
  the live entry wins — newest-first, capped), and drilling into a settled run
  rebuilds its status snapshot (`Harness.Run.Status.from_log_record/1`) and
  replays its transcript from the record via the per-agent parser. Display-only;
  no new storage layer. `mix harness.status` terminal output and the topbar
  tallies stay live-only.

  The dashboard run tables are now **event-driven**: a new fleet PubSub feed
  (`Harness.Dashboard.RunFeed`, topic `harness:runs`) carries
  `{:harness_run_update, status}` on each non-terminal run transition and
  `{:harness_run_settled, status}` on settle, and both tables are
  `Phoenix.LiveView` streams patched per-row from those messages. This replaces
  the previous 1-second tick that re-read and decoded the entire persisted
  results directory from disk on every tick per connected client — history now
  loads once at mount and patches on settle. Sidebar metadata (projects,
  adapters, quota) refreshes on a slow 5-second metadata-only tick (no disk).

  The dashboard **project filter** now works: runs carry a `project_name`
  (threaded onto `Harness.Run.Status` and `%LogRecord{}` from the run's
  `%Project{}`), and the project switcher is a `phx-change` form (a bare
  `<select phx-change>` outside a form silently dropped the event), so selecting
  a project narrows both the active and history tables to that project and "All
  projects" restores the full view. Records persisted before `project_name`
  existed decode as "no project" and appear only under "All projects".

- **Mergeable-bar verification preset — `:elixir_precommit` (Task 97).** A green
  `:elixir` preset verdict could still be unmergeable under the project's own
  `mix precommit` (the divergence surfaced on Task 94: harness graded green
  while the project's 80% coverage gate measured 75.92%). The new
  `:elixir_precommit` preset mirrors that mergeable bar — on top of the default
  stack it adds `format --check-formatted`, `compile --warnings-as-errors`, a
  coverage threshold on `test`, and `doctor --raise` — so a project opts into
  "verdict ⇒ mergeable" via `preset: {:elixir_precommit, cover_threshold: 80,
  exclude: [:integration]}` in its registration config. The gates are ordinary
  `Harness.Verification.Check`s, so they flow through the existing per-check
  verdict display in the dashboard run-detail. The harness self-project now
  registers against `:elixir_precommit`; `:elixir` stays the lighter default.

- **Blocking dispatch — `dispatch__await` (Task 103).** A blocking companion to
  `dispatch__task` for the chat/MCP surface. Where `dispatch__task` returns a
  `run_id` the orchestrator must then poll, `Harness.Dispatch.await/5`
  (`dispatch__await`) subscribes the calling process to the run and **blocks
  until it settles**, returning a compact verdict summary (state, reason,
  per-check results, repair attempts, diagnostics) as the tool result — a
  tool-equipped LLM driving harness gets the answer in one call instead of a
  poll loop. The wait is bounded by a `timeout_ms` argument (default 30 min);
  on expiry it returns a structured `:timed_out` summary carrying the `run_id`
  (the run keeps going and stays observable/cancelable) rather than wedging the
  tool call. The bulky check output and raw agent transcript are dropped from
  the summary; read the `%Run.Result{}` / `LogRecord` for those.
  `dispatch__task` (fire-and-forget) is unchanged alongside it.

- **Per-run token capture — efficiency signal.** Harness now parses each
  adapter's raw transcript for input/output token counts (`Harness.TokenUsage`)
  and threads them through `%Harness.Run.Result{}`, `%Harness.Run.LogRecord{}`,
  and `%Harness.Batch.AgentEvaluation.Entry{}` — so an A/B comparison can weigh
  *token efficiency* (did the adapter solve the task in 50k tokens or 500k?),
  not only the binary pass/fail verdict, and cumulative burn becomes the input
  signal for predictive quota fail-over. Counts are summed across repair
  attempts, so a multi-attempt run's burn is attributable. Per-adapter parsing
  (Claude/Cursor stream-json `usage`, Codex `turn.completed`, Pi
  `message_update` deduped by `responseId`, Grok terminal `end`); a wire format
  that carries no usage records an empty usage (all-`nil`) and never crashes.
  Not dollar accounting — agents run on flat subscriptions.

- **Per-stack working directories — multi-language monorepos.** A project now
  holds a *list* of check stacks (`%Harness.Project{}.check_stacks`) instead of
  one, and each `%Harness.CheckStack{}` carries a `workdir` (relative to the
  worktree root). Because a git worktree is always repo-root-granular,
  `Harness.Verification.run/2` runs each stack's checks in its own
  subdirectory and flattens the results into a single verdict (green iff every
  stack is green). This lets a polyglot repo — e.g. a Rust crate in `rust/`
  next to a Phoenix app in `elixir/` — be graded correctly from one
  repo-root worktree; previously checks always ran at the worktree root, so a
  subdirectory build (rexex's `rust/Cargo.toml`) failed unrecoverably. Project
  registration gains a `stacks: [[preset:/check_stack:, workdir:], …]` form;
  singular `preset:`/`check_stack:` registration (and the `:check_stack` /
  `:checks` run options) remain valid as the one-stack-at-the-repo-root case.
  A misconfigured `workdir` now returns a clear `{:workdir_not_found, dir}`
  instead of a cryptic per-tool "manifest missing" failure.

- **v0_8 chat-orchestrator surface — roadmap browsing, playbooks, flat
  dispatch.** Builds on the v0_7 chat/MCP foundation so an orchestrator can
  pick *and* dispatch work end-to-end through tools, never by shelling `rmap`
  into the live checkout. `Harness.Roadmap.list/2` + `next_bundle/1`
  (`roadmap__list` / `roadmap__next_bundle`) expose a registered project's
  roadmap as JSON-native maps. `Harness.Playbooks` (`playbooks__list` /
  `playbooks__get`) serves version-controlled orchestration recipes from
  `priv/playbooks/*.md`, surfaced in the dashboard chat as prefill chips.
  `Harness.Dispatch.task/4` (`dispatch__task`) collapses the struct-passing
  `ingest → start_run` flow into one flat call taking only JSON scalars
  (project name, task selector, adapter, scrub-key) and returning a
  `run_id` — with the Claude OAuth secret-scrub and the non-delegatable
  ingest-then-dispatch two-step handled internally. The MCP `tools/list`
  now excludes struct-arg tools a stateless JSON caller cannot drive
  (`supervisor__start_run`, the `batch__*` / `agent_evaluation__*` tools);
  they remain on the full in-process Elixir driver surface. Companion fixes:
  keyword-typed params decode from JSON objects without crashing
  `Keyword.get/3`, and integer-keyed `tasks.toml` ids coerce to strings on
  ingest.
- **Chat session persistence + index page (Task 93).** Chat transcripts now
  survive a BEAM restart. `Harness.Chat.Store` is a file-backed term store
  (one `:erlang.term_to_binary` file per session under
  `config :harness, :chat_store, root: …`, written via a `.tmp` sibling +
  atomic rename; `false` disables it). `Harness.Chat.Session` persists its
  messages after each completed turn (bounded to the most recent 200,
  mirroring the live buffer cap) and rehydrates them on init, so reopening
  `/harness/chat/<session_id>` replays the prior turns. The bare
  `/harness/chat` route is now a session **index** listing live sessions
  (`Harness.Chat.Supervisor.list_sessions/0`) merged with persisted-but-dead
  ones — each with a derived label, message count, last-activity, and a deep
  link; a "New chat" button mints a fresh session.
- **v0_7 chat orchestrator (5 shipped, 1 superseded).** Harness now ships
  a third consumer surface alongside the verified-run lifecycle and the
  cheap driver path: a natural-language chat session backed by `claude -p`
  on the Claude subscription tier, with the same harness toolset exposed
  externally as a spec-compliant MCP server. `Harness.Chat.Session` runs
  the multi-turn tool-call loop; `Harness.Chat.Claude` is the default
  backend (raw-Port spawn of `claude -p --output-format stream-json`,
  `ANTHROPIC_API_KEY` scrubbed to force OAuth/subscription, per-session
  cwd for `--continue` resume); `Harness.Dashboard.MCPServer` (anubis_mcp,
  JSON-RPC 2.0 over Streamable HTTP at `/harness/mcp`) exposes the toolset
  to external orchestrators via standard `.mcp.json` HTTP transport;
  `Harness.Chat.Tools` is the single registry both the in-process loop
  and the external MCP surface dispatch through. Non-tool chat works
  end-to-end via the dashboard chat panel.
- **Live MCP tool-use end-to-end (Tasks 83 + 84).** The anubis Streamable
  HTTP transport now starts cleanly under `iex -S mix` — `claude -p`'s
  `initialize` (protocol "2025-11-25") returns 200, `tools/list` surfaces
  the harness manifest, and a tool-needing prompt drives a real
  `tools/call` round-trip the model summarises back. Fix was a one-line
  `transport: {:streamable_http, start: true}` on the `MCPServer` child
  spec in `Harness.Application`: anubis's auto-detect for whether to
  start the transport falls through to `:phoenix, :serve_endpoints`,
  which is `false` for harness because it's not a `phx.server` app
  (the dashboard is one opt-in surface, not the app's primary identity).
  Task 84 added `Harness.Dashboard.ErrorHTML` so the formerly-cascading
  500 — `Phoenix.Template` crashing on a missing template while trying
  to render the underlying error — no longer hides real stack traces.
- New dep `{:anubis_mcp, "~> 1.6"}` (Task 79 v1 audit rework). Direct
  runtime dep that supplies the MCP server behaviour and Streamable HTTP
  transport plug; transitively pulls in `peri` (validator) and `finch`
  (HTTP client) — Bandit on 4018 forwards `/harness/mcp` to it.
- Dev environment now self-registers the harness checkout as the default
  `"harness"` project on boot (Task 72). New `config/dev.exs` populates
  `config :harness, :projects`; `config/config.exs` conditionally imports it
  via `if config_env() == :dev`. `iex -S mix` therefore exposes
  `Harness.ProjectRegistry.lookup("harness")` without a manual
  `register/1` step, making the dispatch examples in
  `skills/harness-driver/SKILL.md` and `docs/dogfooding-workflow.md`
  literally true against the live node. `:test` and `:prod` are unchanged
  (no auto-registration). `config/dev.exs` now also conditionally imports a
  gitignored `config/dev.local.exs` (template: `config/dev.local.exs.example`)
  so operators can register host-local target projects without dirtying
  tracked config — the local file's `config :harness, :projects` call
  replaces the default list, so it must repeat the `"harness"` self-entry.
- Same-task A/B agent evaluation (Task 33). `Harness.Batch.AgentEvaluation.compare/4`
  fans one roadmap item to N adapters in parallel under the existing batch fan-out;
  `Harness.Batch.run_pinned/3` is the lower-level entry that pairs each item with a
  specific adapter. Per-agent metrics (verdict, repair_attempts, duration_ms,
  first_attempt_failed_check_count, agent_diff_size) collect into a `Comparison`
  struct as an additive layer — the verification stack stays the binary pass/fail
  grader. Adapter fail-over never crosses pins.
- Cross-agent grader as an opt-in repair-loop move (Task 59). When the same
  verification check fails twice in a row, the `Harness.Run` gen_statem can spend
  one repair attempt routing the failing diff through `Harness.AuditReview` for an
  opposite-agent verdict (Codex grading Claude, Claude grading Codex), then thread
  the rationale into the same-agent's next repair prompt. Disabled by default
  (`config :harness, :cross_agent_repair, enabled: false`); `:grader` required for
  implementers outside the `:claude ↔ :codex` auto-pair.
- Orchestration playbooks (`Harness.Playbooks`). Version-controlled markdown
  recipes — dispatch-single-task, dispatch-bundle, ab-adapter-compare,
  audit-grade-fix — embedded at compile time from `priv/playbooks/*.md` and
  surfaced as `playbooks__list` / `playbooks__get` tools on the same chat/MCP
  surface, so the orchestrator can fetch a ready-made tool sequence instead of
  assembling one.
- Structured roadmap browse (`Harness.Roadmap.list/2` + `next_bundle/1`,
  tools `roadmap__list` / `roadmap__next_bundle`). Resolves a registered
  project name to its roadmap and returns tasks/bundles as JSON-native maps, so
  the orchestrator picks a task id through a harness tool rather than shelling
  `rmap` from harness's own cwd (wrong root, and broken for `{:github, _}`
  sources).
- Run-detail transcript reworked from a raw stream-json `<pre>` dump to a
  chat-style parsed-event view (`<.transcript_view>`), grouping assistant text,
  tool-call/result pairs, system lines, and passthrough output; `?raw=1` on the
  run URL falls back to the legacy raw buffer.

### Changed

- **Semantic gate decoupled from auto-land (Task 123).** The cross-family
  semantic gate (Task 99) re-checks a green verdict against the task's
  acceptance criteria with an opposite-family grader, but its trigger was
  hardcoded to "on iff the project would auto-land". harness's own self-project
  lands manually, so its dogfooding dispatches ran with the one AC-aware check
  off — Task 108 settled green while objectively incomplete and was
  hand-finished on land. The trigger now consults a project-level
  `semantic_gate` mode on `%Harness.Project{}` — `:always` (gate every green
  run, even under manual landing), `:auto_land_only` (the default; preserves the
  original gate-iff-auto-land behaviour), or `:off` (never gate). A per-dispatch
  `semantic_gate: [enabled: true | false]` run opt — surfaced as a `semantic_gate`
  boolean on the `dispatch__task` / `dispatch__await` tools — forces the gate
  on/off for a single run regardless of landing policy. Default behaviour is
  unchanged (manual-landing projects stay un-gated unless explicitly enabled);
  the harness self-project registration (`config/dev.exs`) opts into
  `semantic_gate: :always` so its dogfooding now gets green-verdict scrutiny.
  The gate machinery (grader pairing, sentinel extraction, `:semantic_rejection`
  repair route) is reused from Task 99 unchanged — only the when-it-fires
  predicate moved.
- MCP surface reworked from a custom REST endpoint (`Harness.Dashboard.MCP`,
  `GET /harness/mcp/tools` + `POST /harness/mcp/call`) to a spec-compliant
  MCP server (`Harness.Dashboard.MCPServer`, JSON-RPC 2.0 over Streamable
  HTTP via `anubis_mcp`) on the same `/harness/mcp` path (Task 79 v1 audit
  rework). External consumers can now drive harness via standard
  `.mcp.json` HTTP transport — a prerequisite for Task 82's `claude -p`
  chat backend. `use Anubis.Server` provides `initialize`, `ping`, and
  prompts/resources defaults via a catch-all clause appended by
  `@before_compile`; harness overrides `tools/list` + `tools/call` to
  reuse `Harness.Chat.Tools` (the in-process chat orchestrator's registry
  + dispatcher), giving one source of truth for both surfaces. Supervised
  process gated on `:dashboard, :enabled` because the Streamable HTTP
  transport requires the Phoenix endpoint.
- `Harness.Chat.Schema.validate/2` now accepts both string-keyed and
  atom-keyed JSON-Schema maps via a single internal `fetch/3` helper.
  Previously only string keys (`%{"type" => "object", ...}`) validated;
  atom-keyed schemas (`%{type: "object", ...}` from
  `Descripex.MCP.tools/1`) silently no-op'd and let downstream code
  emit a generic `path: "#"` violation. Now the validator produces
  precise per-field violations (`path: "#/name"`) regardless of key style.
- `Harness.AgentAdapter` now exposes `permission_flag/2` and `resume_args/1`
  as shared public helpers, hoisted out of the Antigravity / Claude / Cursor
  / Grok / Pi adapters where they were byte-identical (same spirit as
  Task 27's classify/terminate/model_args hoist and Task 39's rule-injection
  hoist). `permission_flag/2` is term-agnostic — it returns the raw stored
  value, so adapters with string-flag modes (Antigravity/Claude/Grok) and
  Cursor's list-flag mode all flow through the same helper. Behavior
  preserved; error tuples (`:unsupported_permission_mode`,
  `:unsupported_session_token`) unchanged. Codex keeps its own
  permission/session shape (id-based resume, list-of-atoms modes) and does
  not adopt either helper.

### Fixed

- Multi-required-param tools dispatched arguments to the wrong positions
  (descripex 0.7 `param_order`). `Harness.Chat.Tools` ordered the positional
  `apply/3` args by `Map.keys/1` (hash order), so a tool like `roadmap__list`
  could receive its `status` value in the `project_name` slot. Now ordered by
  declaration via descripex 0.7's `param_order`; bumped `{:descripex, "~> 0.7"}`.
- Correctness + hardening pass from an independent multi-agent review of the two
  newest subsystems (chat/MCP, Oban dispatch) plus the OTP core. Notable fixes:
  the orphan-kill race in `AgentAdapter.OSProcess.kill/1` (the OS process could be
  reaped and its pid recycled before the external `kill` landed, so the signal now
  precedes the port close); a `MatchError` crash in `Worktree.diff_size/1` on
  unexpected `git diff --numstat` output (binary files); `Worktree.Isolation`
  allowlist patterns containing `/` (e.g. `config/*.exs`) now glob against the full
  path instead of the basename, so they actually match; chat-session terminal
  events (`loop_detected`, `backend_error`, `max_history_bytes`) now broadcast to
  stream subscribers like the abort path already did; UTF-8-safe truncation in the
  dashboard chat buffer (a byte-count prefix no longer splits a multi-byte
  codepoint); a catch-all in `Dashboard.MCPServer` so a novel `Tools.dispatch`
  error shape can't crash the request handler; `Chat.Tools` now distinguishes an
  explicit `null` argument from an absent one; the Oban worker now snoozes
  transient setup failures (boot-race project lookup, ingest/start-run hiccups)
  instead of permanently cancelling them, preserving Oban's restart-resilience,
  while genuinely malformed job data still cancels; `ResultStore.File` writes are
  now atomic (sibling `.tmp` + `File.rename/2`) so a racing reader can't observe a
  torn term file; and `Oban.QueueBootstrap` logs (rather than silently swallowing)
  a Postgres-not-up-at-boot failure.
- `Harness.ResultStore.File.list_run_records/2` now logs and skips undecodable
  term files instead of halting on the first one (Task 73). Previously a single
  atom-stale or corrupt file under `~/.harness/results/runs/` returned
  `{:error, {:invalid_term_file, _}}` for the whole query, masking every
  healthy sibling — breaking the Tidewave dispatch-and-observe pattern
  documented in `skills/harness-driver/SKILL.md`. `collect_records/2` now
  reduces with `Enum.reduce/3` (no short-circuit on `{:error, _}`),
  `Logger.warning`s the reason, and returns `{:ok, [healthy_records]}`.
- Batch test gate-file hygiene no longer leaks stale coordination files or
  orphaned polling shells (Task 70). Gate paths now register per-test cleanup,
  the fake adapter's shell waiter exits if it becomes reparented, and the batch
  test module clears `harness-batch-gate-*` files before and after the suite.
- `Harness.Run` now skips main-checkout pollution detection for adapters that
  declare `worktree_isolation: true` (Task 66). The capability is treated as the
  trust boundary: verified-isolation adapters no longer fail with
  `:checkout_polluted` because an operator or parallel session changed the
  source checkout while the agent worked in its run worktree. Adapters declaring
  `worktree_isolation: false` are still rejected before spawn.
- `Harness.Batch.fill_slots` no longer settles the entire pinned queue when one
  pinned adapter is unavailable (Task 67). In non-pinned mode every queued item
  shares the same adapter list, so one select failure still settles the whole
  queue (unchanged); in pinned mode (`run_pinned/3`, `AgentEvaluation.compare/4`)
  each slot owns its own adapter, so only the head is settled and the rest
  recurse with their own pinned adapters. Surfaced by the Round-5 audit of the
  Task 33 A/B mode delivery.
- `Harness.Batch.AgentEvaluation.from_batch/3` now raises `ArgumentError` on
  adapter/results length mismatch (Task 68). The previous `Enum.zip` would
  silently truncate to the shorter list, dropping entries from the comparison
  without telling the caller.
- `Harness.Worktree.Isolation` pollution allowlist now tracks both source and
  destination of `R old -> new` porcelain lines (Task 69) — an agent moving
  `lib/foo.ex` → `.claude/foo.ex` no longer evades pollution detection because
  the destination is allowlisted. The default allowlist gained a `**/<name>`
  recursive-basename pattern (gitignore-style); `.DS_Store` upgraded to
  `**/.DS_Store` so `docs/.DS_Store` is also ignored, not just the repo-root
  copy.
- Codex adapter now pins its working root via exec-level `--cd <worktree>` in
  addition to the Port's `:cd` (Task 41). Without the flag, Codex's heuristic
  workspace resolution could follow a linked worktree's `.git` pointer back to
  the main checkout's common git-dir and silently edit the parent repo — same
  shape as Task 32's Antigravity bug.
- `Harness.Worktree.Isolation` checkout-pollution diff now filters porcelain
  lines against an allowlist (Task 60). Defaults cover `.claude/`, `.DS_Store`,
  and common editor lock/temp files; overridable per project
  (`%Harness.Project{}.pollution_allowlist`), per run
  (`Harness.Run.Supervisor.start_run/4`'s `:pollution_allowlist`), or via
  app config. Roadmap files are deliberately NOT allowlisted — a genuine
  agent mutation to roadmap state is still a bug worth catching.
- Failure classification (Task 64) now clips `Outcome.output` and each
  `CheckResult.output` to its trailing 4 KiB before quota-pattern matching.
  Agents constantly read source and docs containing the trigger words
  (`quota`, `rate limit`, `subscription`), so matching the full stream-json
  transcript was wildly false-positive-prone — a benign mid-run source read
  could short-circuit the repair loop with a false `:quota_exhausted`
  classification. Terminal API errors (`billing_error`, HTTP 429, etc.)
  still detect correctly when they appear in the agent's terminal envelope.
- Dashboard transcript pane now backfills on mount instead of starting empty
  (Task 63). The per-run transcript at `/harness/runs/:run_id` was fed by
  fire-and-forget `Phoenix.PubSub` broadcasts, so opening the page mid-run
  showed "Waiting for output…" until the next chunk arrived — often minutes
  later for a quiet Claude session. The `Harness.Run` gen_statem now owns a
  bounded 200 KiB transcript buffer + a monotonic seq counter; the driver's
  `:on_output` callback sends each chunk to the gen_statem (which appends and
  re-broadcasts with seq); the LiveView subscribes first, fetches the buffer
  via the new `Harness.Run.transcript/1`, then drops PubSub messages whose
  `seq <= last_seq` to dedup chunks that landed during the snapshot call.
  Broadcast tuple is now `{:harness_transcript, run_id, seq, chunk}` (was
  3-element). `Harness.Dashboard.Transcript.append/3` is the shared trim
  helper so producer and consumer agree on the 200 KiB cap.

### Added

- Phoenix LiveView dashboard with embedded Oban Web (Task 50, closes milestone
  v0_5). `Harness.Dashboard.Endpoint` boots a standalone Bandit listener on
  port 4018 (configurable via `:harness, :dashboard, port:` or
  `HARNESS_DASHBOARD_PORT`), gated by `:dashboard, :enabled` plus a
  `Code.ensure_loaded?(Bandit)` check so mountable consumers can route the
  LiveView into their own endpoint instead. `Harness.Dashboard.Router` mounts
  `oban_dashboard("/harness/oban", oban_name: Harness.Oban)` for queue-centric
  introspection, then `live("/harness", ..., as: :dashboard)` and
  `live("/harness/runs/:run_id", ..., as: :dashboard)` for the harness-native
  view. `Harness.Dashboard.Live` renders a project switcher off
  `Harness.ProjectRegistry.list/0`, per-bucket counts and an active-run table
  off `Harness.StatusView.snapshot/0` + `classify/1`, and a per-run drill-down
  off `Harness.Run.status/1` — kept fresh by a 1s `:tick`. A live transcript
  pane subscribes to `Phoenix.PubSub` topic `harness:run:<id>:transcript`,
  fed by a new `:on_output` callback on `Harness.AgentAdapter.Driver.run/3`
  via `Harness.Dashboard.Transcript.broadcast/2` — every output chunk the
  agent emits is published to the topic, the LiveView keeps the last 200 KiB
  in a bounded buffer. Bandit flipped `optional: true` so a mountable
  consumer is not forced into a second HTTP server.
- GitHub project sources: `%Harness.Project{}` now accepts `source: {:github, url}`
  alongside the existing `{:local, path}`. On first run, harness clones the URL
  into a per-project cache directory under `:harness, :project, :cache_root`
  (default `~/_DATA/harness/projects`); on every subsequent run, harness
  `git fetch`es and fast-forwards the default branch, so a run never grades
  against a stale `main`. Cache-recovery is transparent: if the cache directory
  was removed between runs, the next call re-clones. New modules
  `Harness.Project.Source.Local` and `Harness.Project.Source.Github` carry the
  per-variant surface (`url/1`, `local_path/2`, `ensure_local/2`).
  `Harness.Worktree.create/2` now calls `Project.ensure_local_repo/2` before
  branching, so a `{:github, _}` project transparently boots from a fresh clone
  or a fetched cache. (Task 47)
- Precommit gate now fails on Sobelow findings (`sobelow --exit --skip`) and
  ships a `mix sobelow.baseline` alias for deliberately marking the current
  findings as skippable.
- Oban-backed dispatch for registered projects: runtime deps now include Oban,
  Ecto SQL, and Postgrex; `Harness.Repo` owns the Postgres connection; Oban
  jobs persist one run per roadmap item in per-project queues named
  `project_<name>`; `Harness.Run.Worker` spawns the existing run gen_statem and
  maps terminal results onto Oban's `:ok` / `:snooze` / `:cancel` worker
  return contract. (Task 48)
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
