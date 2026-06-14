# harness — CLAUDE.md

**Repo:** [github.com/ZenHive/harness](https://github.com/ZenHive/harness) (public, default branch `development`).

## Always-on includes (core only)

@~/.claude/includes/critical-rules.md
@~/.claude/includes/code-style.md
@~/.claude/includes/rmap.md

> **Trimmed 2026-05-30.** The previous version `@`-imported 14 includes + the 43 KB harness-driver SKILL (~44k tokens always-on), which drove compulsive re-reading on Opus 4.8. The eager floor is now the three above — `critical-rules` (guardrails), `code-style` (KPIs), `rmap` (roadmap decision layer, used every session). Harness workflow (`harness-workflow.md`) is load-on-demand below — same adoption path as other repos: `@~/.claude/includes/harness-workflow.md`. `response-conventions` is inherited from `~/.claude/CLAUDE.md`, not re-imported here. Everything else is **load-on-demand** — pull it only when the trigger matches.

## Load-on-demand (don't auto-load — read the file or invoke the skill when the trigger hits)

| When you need… | Load |
|---|---|
| `mix test.json` flags / jq recipes | Skill `elixir:ex-unit-json` |
| `mix dialyzer.json` flags / fix_hints | Skill `elixir:dialyzer-json` |
| `mix` / `ex_dna` / `ex_ast` command surface | Skill `elixir:development-commands` |
| rmap CLI: status/score/new/render/delegate | Skill `task-driver:rmap` |
| D/B/U scoring, ceremony floor, task-writing | Skill `elixir:roadmap-planning` + `@~/.claude/includes/task-writing.md` |
| Session-per-phase / batched-execution / evaluator-separation rules | `@~/.claude/includes/workflow-philosophy.md` |
| Worktree-per-branch workflow | `@~/.claude/includes/worktree-workflow.md` |
| Harness delegate→verify→repair→land workflow (portfolio adoption) | `@~/.claude/includes/harness-workflow.md` |
| Driving harness as a consumer (dispatch patterns, result shapes) | `@skills/harness-driver/SKILL.md` |
| Phoenix project setup / gen.auth | Skill `phoenix:phoenix-setup` |
| Net-new / redesign frontend surface (distinctiveness IS the goal) | Skill `frontend-design:frontend-design` — **not** for incremental work in the existing dashboard design system (match `tokens.ex` + `components.ex` patterns instead; skill is at most a reference) |
| The "message across instances" (philosophical anchor) | `@~/.claude/includes/across-instances.md` |

**Situational skills** (invoke via Skill tool when trigger matches; don't auto-load): `elixir:reach` (PDG/SDG, `mix reach.otp`), `elixir:web-command` (browser/dashboard work), `elixir:agent-economy` (descripex surface), `elixir:elixir-setup` (dep-stack / alias edits).

## Elixir methodology (the non-obvious mandates — compressed from development-philosophy.md)

The full include is verbose and mostly restates mainstream Elixir. These are the bits the model would otherwise get wrong:

- **`@spec` on every function — `def` AND `defp`.** Not the community publics-only default. Configure `{Credo.Check.Readability.Specs, [include_defp: true]}`. Suppress macro-generated `defp` per-callsite, don't drop the check.
- **Doctests are documentation, not tests.** Happy-path / API-shape examples only. Edge cases, boundaries, unions, error paths → ExUnit `describe` blocks. A second doctest "to cover the empty case" is the failure mode — write an assertion instead.
- **`TODO:` prefix for all temporary code / "for now" / "in production" notes** so Credo tracks the debt. No prefix = invisible debt.
- **No IO in `@doc` examples.** `@doc` demonstrates API usage, not console output.
- **Library-first / precedent-first (anti-hedging).** Before calling a cost a real trade-off (case-conversion, option validation, wire-format friction) → check hex.pm. Before objecting a macro/DSL "could grow knobs" → name the specific Elixir precedent that fails the same way (Phoenix.Router, Ecto.Schema, NimbleOptions, Ash) or accept it. Generic FUD without a named failure pattern is hedging.
- **Internal-API markers:** `defp` first; `@doc false` for must-be-public-but-internal; `@moduledoc false` on a whole `MyLib.Internal` module; `@opaque` for tokens/handles whose structure is implementation detail.

## rmap is ours

The `rmap` CLI (the roadmap substrate `roadmap/tasks.toml` uses) is a sibling Rust project we own at `../rmap/` (`/Users/efries/_DATA/code/rmap/`). If the roadmap workflow needs a CLI change — new field, query, render, or `delegate --to` target — edit it there; don't work around a gap in harness. The `task-driver:rmap` skill is the usage contract; `../rmap/` is the source.

**AI driver surface (canonical for orchestrators):** `@skills/harness-driver/SKILL.md` — **load on demand** when driving harness as a consumer. Stable contract for delegation patterns, non-delegatable handling, result interpretation, sharp edges. Any change to public driver surfaces must update it.

> **Two harness skills are canonical HERE, not in `~/.claude/includes` — propagate with `scripts/sync-harness-skills.sh`.** `priv/includes/harness-workflow.md` (the portfolio implement→review→land contract) and `skills/harness-driver/SKILL.md` (this driver surface) are the source of truth. The general marketplace sync (`claude-marketplace/scripts/sync-skills-from-includes.sh`) **deliberately excludes** them. After editing either, run `scripts/sync-harness-skills.sh` — it fans the workflow include out to `~/.claude/includes/` **and** both `plugins/harness/skills/*/SKILL.md` in the marketplace (frontmatter preserved, idempotent, `--dry-run` to preview). Skip it and the installed include + marketplace skills silently drift from the source.

## Commands

Toolchain: **Elixir 1.20.0 / OTP 29** (asdf) — pinned by the repo-local `.tool-versions` (`elixir 1.20.0-otp-29` / `erlang 29.0.1`). `mix.exs` floors at `~> 1.18`; a repo-local `.tool-versions.1.18` (1.18.4/OTP27) pins the lower-bound compat target — `cp .tool-versions.1.18 .tool-versions` to build against it. Postgres required for the Oban dispatch layer.

> **Sync `development` before committing when auto-land is on.** With `landing_policy: :auto`, the lander is a *second committer* to `origin/<target>` — it ff-pushes from a detached worktree and deliberately **never touches your checkout**, so your local `development` ref drifts behind origin after every autonomous land. **Before any commit/push, `git fetch origin development && git rebase origin/development`** (or `git pull --rebase origin development`) — rebase, because you'll often have local commits the lander doesn't. Skip it and you get a stale base / non-ff push reject. A clean rebase → `git push origin development` is the completing step; just do it. If the rebase still has unresolved conflicts or the push is non-ff, stop and surface it — don't force-push a shared branch.

| Task | Command |
|---|---|
| Run the node | `iex -S mix` — boots the app, Oban (Postgres), and the dashboard on `http://localhost:4018` (routes `/harness`, `/harness/oban`, `/harness/mcp`, `/tidewave/mcp`). **Long-lived; the user starts it manually — don't boot it yourself.** |
| First-time DB | `mix ecto.setup` (creates, migrates, and runs `priv/repo/seeds.exs` when present). DB name/user overridable via `HARNESS_DB_NAME` / `HARNESS_DB_USER` (defaults `harness_dev`, `$USER`). |
| Tests | `mix test.json` — AI-friendly JSON output; **use over bare `mix test`** (load `elixir:ex-unit-json` for flags/jq). `:integration` tests (real agent CLIs, live DB) are **excluded by default** — add `--include integration`. |
| Single test | `mix test.json test/harness/run_test.exs:42` · re-run only failures: `mix test.json --failed` · coverage: `--cover`. |
| Fast gate | `mix check.fast` — `format --check-formatted` + `compile --warnings-as-errors` + `credo --strict`. |
| Pre-commit gate | `mix precommit` — adds `doctor --raise`, `test.json --cover --cover-threshold 80 --exclude integration`, `sobelow`. Hook-bound (180s); **dialyzer is deliberately not here** (cold-PLT timeout). |
| Before PR / handoff | `mix precommit.full` — `precommit` + `dialyzer.json`. (No CI workflow exists yet — this is the only mergeable-bar gate.) |
| Sync harness skills | `scripts/sync-harness-skills.sh` (`--dry-run` to preview) — after editing `priv/includes/harness-workflow.md` or `skills/harness-driver/SKILL.md`, propagate to `~/.claude/includes/` + the marketplace `harness` plugin skills. The general marketplace sync excludes these two. |

**Per-edit hooks already run this stack** (`format`, `compile`, `test.json`, `credo`, `dialyzer.json`, `sobelow`, `doctor`) on every touched file — don't re-run a check the hook just graded. Full-suite `precommit.full` earns its cost only before a PR/merge, after `mix deps.get`, or on a branch switch (see global CLAUDE.md § "Don't Re-Run Hook-Driven Checks").

## What This Is

`harness` is an OTP-native Elixir engine an **AI orchestrator drives end to end**: pull a task from the rmap roadmap → **implementer AI** works in an isolated git worktree → **reviewer AI** (cross-family) reviews, runs the project's checks itself, fixes inline, and renders the verdict → **MERGE** (lander rebase + push) → **audit AI** post-merge. Consumer surfaces: Elixir API (IEx / tidewave / another BEAM process), the Phoenix LiveView dashboard, and an MCP server. It is a long-running OTP node that orchestrates **N registered target projects** (Elixir, Rust, anything an agent can check) concurrently.

**Primary user is an AI agent, not a human** — harness is the OTP-native automation of the worktree → implement → review → merge → audit loop this repo's owner runs by hand (see `~/.claude/includes/worktree-workflow.md` for the manual analogue).

**Not a wrapper around one agent.** The `AgentAdapter` behaviour (Task 3) is a deliberately thin contract: *invoke* an agent, *capture its raw output*, declare capabilities — nothing more. **No normalized event model**: the consumer is an AI that reads each agent's raw JSON natively; harness decides "did the job succeed?" from the **reviewer AI's verdict artifact**, never from the implementer's self-reported result.

## Architecture

- **Elixir / OTP, not TypeScript.** harness *is* N concurrent supervised agent runs needing crash isolation, timeouts, retries, observable state. One run = one supervised `gen_statem`; one batch = a `DynamicSupervisor`.
- **Core loop.** rmap task → implementer AI in isolated worktree → commit → **reviewer AI is the gate** (reviews against acceptance criteria, runs the project's checks itself, fixes inline, writes `.harness/review.json` verdict) → approve ⇒ done ⇒ merge ⇒ post-merge audit AI; reject ⇒ failed, task back to queue. Implementer/evaluator separation is agent/agent (cross-family), not agent/script — see "The Agent-Gate Workflow" below.
- **Thin adapter pattern.** One adapter per agent: invocation + raw capture + capability declaration. Behaviour `Harness.AgentAdapter` — required callbacks `capabilities/0` + `rule_channel/0` + `build_command/1`; `classify_message/2` + `terminate/1` default via `use Harness.AgentAdapter` + defoverridable. `AgentAdapter.invoke/2` does the generic Port spawn. `build_command/1` threads caller-controlled env (`Invocation.env`, set/scrub pairs → Port, Task 25). Harness-owned rules delivered ahead of `build_command/1` by `AgentAdapter.attach_rules/2` (Task 39), dispatching on `c:rule_channel/0`: `:system_prompt_file` (Claude), `:codex_ephemeral_file` (Codex/Pi), `:cursor_ephemeral_file` (Cursor), `:prompt_preamble` (Grok/Antigravity), `:none` (test doubles). Every adapter must pass `Harness.AgentAdapter.ConformanceCase` **unchanged** — a leak gets fixed in the behaviour, not patched in the adapter.
- **No agent-output parsing.** Raw passthrough is simpler *and* more robust — agents ship 40+ releases; a JSON-format change is absorbed by the AI reading the transcript, not by breaking a normalization layer.
- **Path discipline:** raw-output capture is hot-path-adjacent (allocation-light); run/batch lifecycle is warm-path OTP state; dashboard / MCP is cold-path.
- **Multi-project federation (shipped, v0_5; simplified by the agent-gate rebuild).** `%Harness.Project{}` (Task 46) carries `source` (`{:local, dir}` or `{:github, url}` — Task 47), `check_command` (free-text hint handed to the reviewer AI, e.g. `"mix precommit"` — the reviewer runs and judges it itself; multi-language monorepos just describe both commands in the hint), `roadmap_path`, `concurrency_cap`, `landing_policy`, `target_branch`. `Harness.ProjectRegistry` GenServer holds them. The old declarative `check_stacks`/presets/`Harness.Verification` machinery is **deleted** — see "The Agent-Gate Workflow" below.
- **Oban = dispatch layer** (Task 48): queue-per-project gives per-project concurrency caps + restart resilience (jobs survive BEAM death in Postgres). `Oban.Plugins.Cron` (Task 51) enables autonomous roadmap polling. Dashboard (Task 50): `Harness.Dashboard.Endpoint` standalone Bandit on **4018** (conditional behind `:dashboard, :enabled` + `Code.ensure_loaded?(Bandit)` so mountable consumers aren't forced into a 2nd HTTP server), Oban Web at `/harness/oban`, MCP at `/harness/mcp`, Tidewave MCP in dev — all on the one port.
- **Autonomous landing (shipped, v0_9; simplified by the agent-gate rebuild).** `Harness.Lander` is the merge-train: a run the reviewer approved on a project with `landing_policy: :auto` + `target_branch` enqueues a landing job on the project's serialized `landing_<name>` Oban queue (limit 1). The lander rebases the run's `harness/<run-id>` branch onto `origin/<target>` in a fresh **detached** worktree and fast-forward-pushes (never `--force`; the operator's checkout is untouched; **no re-verification** — the reviewer already gated the work). A rebase **conflict** is the one MERGE-node judgment call: instead of a blind re-dispatch, the lander hands the conflicted worktree to a cross-family merge-resolver agent (`Harness.Lander.Resolver`, Task 189) that reconciles the markers (keep-both by default); harness then mechanically stages, asserts zero leftover markers, and `rebase --continue`s — on **resolver failure the lander never re-dispatches**: the reviewer-approved `harness/<run-id>` branch is retained, the task is marked `blocked`, and the conflict is witnessed (a still-conflicted tree is never landed; the resolver never re-runs checks). Recovery is operator-driven `dispatch-reland` (a zero-token re-land once the conflicting change has settled) — committed, reviewed work is recovered, never thrown away and re-implemented. A successful push enqueues the post-merge audit job. `Harness.Notification` fires witness events (land / blocked) to configured sinks — read-only by design, never a gate. Run recovery: `hold`/`steer`/`resume` on the gen_statem (Task 150). Cron autonomy: master + per-project toggles, persisted under `~/.harness` (Tasks 109/110).
- **Agent KPIs + capability routing (shipped, v0_10; re-keyed to reviewer outcomes).** `Harness.ResultStore` (behaviour: File default, Postgres when `repo_enabled`) persists run records best-effort at settle time; `Harness.AgentKPI` is a pure read-only rollup (success = reviewer approved; first-attempt-pass = approved with zero reviewer fixes; duration p90; cost-to-approved); `Harness.CapabilityScore` (verdict + reviewer fix-diff size + the reviewer's ratings block) gives per-`{agent, domain}` scores that `dispatch-recommend` routes on (explore/exploit). The mechanical benchmark corpus is deleted — the reviewer's KPI ratings replaced it as the scoring input.

## Orchestration Library — Build a Thin Core (settled, Task 2)

Core is textbook OTP (Port per run, `gen_statem` per run, `DynamicSupervisor` for batches). Adopting a niche orchestration lib adds risk, not leverage. Evaluated `opal`, `gen_agent(_ensemble)`, `altar_ai`, `ex_mcp`, and SDKs `claude_code`/`codex_sdk` — **outcome: build thin core, adopt none, uniform Ports.** Full rationale: `docs/orchestration-library-evaluation.md`.

- **None of the orchestration libs spawns/supervises an external OS process** — no Port in any of them; they coordinate *in-process* LLM agents, harness orchestrates *external* headless CLIs.
- **`claude_code` / `codex_sdk` are CLI wrappers**, not native reimplementations. An SDK's headline value is a normalized event model, which harness's raw-passthrough design deliberately discards. So **uniform Ports for every adapter**.
- **Cold-path surface = dashboard + Oban Web + MCP, all on one Bandit.** Mountable into a consumer Phoenix endpoint or standalone. MCP (`Harness.Dashboard.MCPServer`, on `anubis_mcp`) exposes the descripex-`api()`-annotated driver surface (`Harness.Manifest`) as MCP JSON-RPC 2.0 over Streamable HTTP at `/harness/mcp`. `Harness.Chat.Tools` is the single source of truth for both the in-process chat dispatcher (`Harness.Chat.Session`) and the MCP surface. `Harness.Roadmap.list/2` + `next_bundle/1` let the orchestrator browse a registered project's roadmap as structured data. `Harness.Playbooks` layers orchestration recipes as compile-time-embedded `priv/playbooks/*.md`.
- **Oban = queue + persistence + cron, NOT a worker engine.** It *wraps* `Harness.Run` gen_statem: `Harness.Run.Worker` takes `{project_name, item_id, adapter_module}`, spawns the gen_statem, threads terminal state into Oban's contract. gen_statem stays load-bearing (runs are minutes-to-hours with rich live state).
- **Dispatch retry vs in-run review — keep separate.** Oban owns dispatch-level persistence/retry, and it is **crash-only mechanical** (Task 163): `Harness.Run.RetryPolicy` is pure backoff arithmetic — a settled run is never re-run by policy code. Quality outcomes are handled *inside* the run by the reviewer AI (fix-and-approve is the near-absolute default; rejection puts the task back in the queue). Open-source Oban has no cross-queue global cap; effective ceiling = sum of `project_<name>` queue limits.
- **`Harness.AgentRegistry` is a soft hint, not a contract** (Task 40, option (b)). Unavailability lives in GenServer state only — no persistence/TTL; restart clears it **by design**. It's a *latency optimization*; *correctness* lives in Oban. Rationale: `lib/harness/agent_registry.ex` `@moduledoc`.

## The Agent-Gate Workflow (settled, 2026-06-03 — THE architecture, do not re-litigate)

**The workflow:** `worktree → implementer AI → reviewer AI (THE GATE) → MERGE → audit AI`. There is **no mechanical test runner / verification gate** in harness. The reviewer AI runs the project's checks itself — having harness also run them mechanically added wall-clock, crash surface, false verdicts, and config burden for zero added judgment.

> **Status:** rebuild landed 2026-06-03 (hand-built). `docs/agent-gate-workflow.md` is the spec.

**The principle (extends 2026-06-02's "Judgment Lives in Agents"):** *everything that interprets meaning* — is the work good, why a run failed, what an empty diff means, whether code satisfies acceptance criteria, whether the build/tests pass *in a way that matters* — **is an agent's job, never harness code.** Harness code is mechanical substrate only: worktrees, git, Ports, Oban persistence, counters, timers, reading the reviewer's verdict file.

> ## 🧭 THE MANTRA — count facts in code; write the *meaning* of facts with an AI.
>
> This is the leitmotif of every harness session. Read it before you touch this codebase; recite it when you design, review, or refactor.
>
> Harness code may **count** a fact: `run_count`, summed tokens, a duration, a file's bytes, a git ref, a queue depth. It may never **judge** the fact: *who is good at this work, why this run failed, whether this code is good, whether this run is worth watching, which agent to route to.* Judgment is written by an agent — into a verdict artifact, an assessment file, a prompt's reasoning — never computed by harness.
>
> **The failure mode is not just "a classifier in code." It is harness counting the facts AND computing their meaning.** When you see aggregation that *fuses* facts into a verdict, score, ranking, or route — magic weights (`0.5·x + 0.3·y`), percentile gates, keyword classifiers (`~r/security|bug/`), staleness decay, "is this high-stakes enough" branches — **that is judgment wearing arithmetic's clothing.** Delete the arithmetic; persist the raw facts; have an agent write the judgment from them, on demand or as a cached artifact. The reviewer already writes per-run `ratings` — do not let harness *recompute* a verdict from those numbers; an AI that reads the raw records judges better than any formula, and explains itself.
>
> **The test, every time:** is this code *counting* (mechanics — keep) or *deciding what the count means* (judgment — an agent writes it)? When in doubt, it's judgment. The proof is in the git log: ~1,400 LOC of KPI/score/route arithmetic and every run-lifecycle false-verdict bug came from harness computing meaning it had no business computing.

**The evidence that settled it:** every run-lifecycle bug from 2026-05-26 → 06-03 (tasks 153–163, 168, 169, 171, 172, the task-41 verifier crash, the task-172 failure) traced to the *harness verification/lifecycle machinery* — false reds, false greens, verifier crashes, timeout misconfig, preset gaps. Zero traced to an agent's judgment. 32 salvage/repair/fix commits in 257.

**The stages:**

- **Implementer AI** — works in the isolated worktree, commits. Its self-report is never trusted.
- **Reviewer AI (cross-family, mandatory, THE gate)** — gets worktree + task + acceptance criteria + implementer transcript + diff stat + the project's `check_command` hint. It reviews, **runs the checks itself**, fixes inline (own edits, own commits), then writes `.harness/review.json`: `{"verdict": "approve"|"reject", "report": "...", "ratings": {...}}`. Harness mechanically reads the file: approve → `:done` → merge; reject/missing → `:failed`, task back to queue. The ratings block scores the implementer (performance, truthfulness, code quality, idiom usage) and feeds AgentKPI.
- **MERGE** — lander: fetch → detached worktree → rebase onto `origin/<target>` → ff-push. No re-verification.
- **Audit AI (post-merge, batched, best-effort)** — third-family agent audits the unaudited commit range on the target branch, fixes hygiene inline, commits `audit(...)`, pushes. Never blocks, never reverts.

**Rules for every session:**

- A run-lifecycle bug is fixed by **moving judgment into an agent prompt or verdict artifact** — never by adding a branch/regex/filter/classifier to harness code.
- Do not reintroduce: `Harness.Verification`, `Harness.CheckStack`, presets, verdicts, `:verifying`, baseline anything, repair loops, semantic gates, quota regexes, `review_green`, `max_review_iterations`, lander re-verification, the mechanical benchmark corpus.
- What stays code (the test: is it mechanical?): worktrees, git, Ports, Oban persistence, counters, timers/watchdogs, reading `.harness/review.json` / `.harness/audit.json`.

## Agent Headless Entry Points (domain reference)

| Agent | Headless invocation | Raw output format |
|---|---|---|
| Claude Code | `claude -p` | `--output-format stream-json` |
| Cursor | `cursor-agent -p` | `--output-format stream-json` |
| Codex | `codex exec` | `--json` |
| Grok | `grok -p` / `agent` subcommand | `--output-format streaming-json` |
| Antigravity | `agy -p` | none (plain text) |
| Pi (pi.dev) | `pi -p` | `--mode json` |

All six driven over OTP Ports — uniform, no per-agent SDK. harness captures raw, never parses/normalizes. **Exit code is unreliable**: derive *termination* from Port close + timeout guard; derive *success* from the reviewer AI's `.harness/review.json` verdict — never `$?`, never the implementer's self-report.

**Three-axis adapter contract** (don't conflate):
- **Agent vs model — pin the model per run.** Each adapter threads `Invocation.model` → its CLI's `--model` flag (`AgentAdapter.model_args/1`), so the *agent* (`assignee`) and the *model that agent runs* (`model`) are orthogonal. This is most load-bearing for **Cursor: it is a multi-model front-end, not "the Composer agent."** `cursor-agent --list-models` (verified 2026-06-07, CLI `2026.06.04`) carries `composer-2.5`/`composer-2.5-fast` (its in-house default) **plus `claude-opus-4-8-thinking-high` / `claude-opus-4-8-max` (Opus 4.8 1M)**, Sonnet 4.6, GPT-5.5, Gemini 3.1 Pro, Grok 4.3, Kimi K2.5. So a `cursor` dispatch with `model = "claude-opus-4-8-thinking-high"` is a full Opus-tier implementer/reviewer — **route Opus-grade tasks to cursor, not just to claude.** Pin it on the rmap task (`model = "<id>"`); with no task pin, the operator-set per-agent default fills in (`Config.agent_model/1` ← the `{:agent_model, agent}` "Agent models" settings card), and an unset default is **rejected, never silently run on the agent's CLI default** — a model-capable adapter that resolves to no model fails the dispatch with `{:model_required, agent}` (`AgentAdapter.invoke/2` + the dispatch/reviewer fail-fasts; the guard against a sticky premium CLI default burning the budget on every later run). So the implementer precedence is **task `model` → `{:agent_model, agent}` → REJECT**; the **reviewer** has no task-pin axis, so its model comes *solely* from `{:agent_model, agent}` for the selected reviewer adapter's agent (`Run.reviewer_model/1`, Task 256 — a model-capable reviewer with no configured model → `{:model_required}`, rejected before the reviewer Port spawns). The single exemption is **antigravity** (`Capabilities.model_families: []`, its `agy` CLI has no `--model` flag): it declares itself model-*incapable* and so legitimately runs model-less. Model IDs churn — re-run `--list-models` before trusting a literal string. (Per the run ledger, cursor (10/63) and grok (2/63) are both underused vs codex (31) / claude (20); cursor-on-Opus is the cheapest way to rebalance.)
- **🚨 Dispatch routing — do NOT dispatch to the `claude` adapter; want gpt-5.5 → use `codex`.** The orchestrator already runs on the Claude Max subscription, so dispatching implementer/reviewer runs to the **`claude` adapter double-bills that same subscription and races its limits** — don't pin a dispatch task to `claude` to "get a strong model." For headless dispatch prefer **`codex`, `cursor`, `grok`**. **`codex` IS how you get gpt-5.5** → `assignee = "codex"`, `model = "gpt-5.5"`. Opus-grade without claude → `cursor` on `claude-opus-4-8-*` — **but cursor-Opus draws a *monthly* token budget that exhausts**, and when spent harness's catalog still lists it as available (no auto-block), so it will route and silently degrade/fail. **If cursor-Opus is exhausted: route the work to `codex`/gpt-5.5, and `model_availability-block_model` the cursor-Opus id** (with a `blocked_until` ≈ month end) so the cron poller can't pick it.
- **Renderable vs executable**: `rmap delegate --to` now renders a native prompt for all six adapters (`claude`/`codex`/`cursor`/`grok`/`antigravity`/`pi`), so each is a first-class `Roadmap.ingest(agent: …)` target dispatched directly on its own adapter — the old non-delegatable two-step is gone. rmap can also render `droid`, but harness has **no Droid adapter**, so `:droid` is rejected at the ingest/dispatch boundary (`{:invalid_agent, :droid}` / `{:unknown_adapter, "droid"}`). Adding an executor is two-sided: an rmap-lib `--to` target (the rmap binary is ours, `../rmap/` — already done for `droid`) **plus** a harness `AgentAdapter` listed in `Roadmap`'s `@valid_agents`.
- **Worktree isolation**: all six shipped adapters declare `worktree_isolation: true`. `agy` does **not** honor Port `cwd` alone (Task 32/198) — the adapter pins the run worktree via `--add-dir <cwd>` in `build_command/1`, mirroring Codex's `exec --cd` fix (Task 41). `Harness.Run` trusts declared isolation and skips the main-checkout pollution snapshot for isolating adapters.

## Reach Is in the Dep Stack

Core is OTP-dense. `mix reach.otp` (state-machine analysis, dead replies, missing handlers, supervision topology) and `Reach.independent?` are on-point. Reach is a dev/test dep (`runtime: false`); invoke the `elixir:reach` skill for OTP introspection / static analysis here.

## Status

**ROADMAP.md (rendered from `roadmap/tasks.toml` by `rmap`) is the live source of truth — start every session with `rmap next`.** High-level snapshot, not a changelog; per-task history lives in `tasks.toml` and `.remember/`.

- **Bootstrap (hand-built):** Tasks 1–8, 23, 24.
- **Phases 1–4 (dogfooded):** all 6 adapters, conformance suite (12), resilience bundle (9/10/11), caller-controlled env (25), non-delegatable contract (31), rule injection (39), capability/availability registry (16/40), StatusView (18), structured logging (19), AuditReview grader (58).
- **Phase 7 / v0_5 (multi-project + dashboard, hand-built):** Project + ProjectRegistry (46), GitHub sources (47), template (49), Oban dispatch (48), Cron poller (51), dashboard + Oban Web on 4018 (50). (CheckStack + presets 44/45 shipped here; deleted by the agent-gate rebuild.)
- **Phase 9 / v0_7 (chat orchestrator):** Manifest (75), Chat.Session (76), MCP server on anubis_mcp (79), Chat.Claude subscription-OAuth backend (82), ChatLive + tokens (78). Task 77 (hand-rolled Anthropic client) **deleted as superseded** — violated "Claude subscription, not API" + library-first. **Library-first rule reasserted.**
- **v0_8 (dashboard operator UX) + v0_9 (autonomous landing) — done:** flat `dispatch__task`, run kill (94), per-stack `workdir` (92), chat persistence (93), merge-train lander + resilience (100/101), witness notification sinks (102), `dispatch__await` (103), cron autonomy toggles (109/110/111), reflex floor (112), run recovery hold/steer/resume (150), per-project landing policy (155).
- **v0_10 (agent KPIs & capability routing) — done:** AgentKPI + dashboard (114/115), capability domains/scoring/routing (116–122), Postgres result store (137/139). Re-keyed to reviewer outcomes by the agent-gate rebuild; the benchmark corpus + agent-eval corpus task (151) were deleted/superseded.
- **v0_11 (reviewer-pair lifecycle, phase 15) — superseded:** `:reviewing` state (161), `review_green` + empty-diff routing (162), deletion pass (163) shipped, then the agent-gate rebuild (2026-06-03) absorbed and replaced the whole design (`review_green` deleted, review made mandatory). Tasks 164/166/169/170/172 superseded.
- **v0_12 (agent-gate rebuild + post-merge audit) — landed 2026-06-03, hand-built:** run-lifecycle rewrite (reviewer artifact gate), `Harness.Audit` + `Harness.Audit.Worker`, lander simplification, KPI re-keying. Confirm current state via `rmap next` — this list drifts.

## Dogfooding — harness Builds harness

From the core loop onward, harness is developed *by* harness. **Once bootstrap is `done`, every remaining pending task is delivered by dispatching it through harness.** Hand-build only what harness cannot yet do for itself. Runbook: `docs/dogfooding-workflow.md` (harness-incubator specifics + script template); general harness workflow contract (adopt via @ import in any repo): `@~/.claude/includes/harness-workflow.md`. Driver reference: `@skills/harness-driver/SKILL.md` (load on demand; changes to `AgentAdapter.*` / `Run.Supervisor` / `Batch` / `Roadmap` / Invocation/result shapes must update it).

- **Roadmap = harness's own test corpus.** A task harness fails to deliver is a harness bug, filed via `rmap new`, not worked around by hand-building.
- **🚨 Right-size every task to ONE dispatch cycle — split on coupling, never on size.** A task is one implement→review→land unit, not the smallest namable edit; each dispatch pays a full loop's overhead, so a sub-threshold task is a manufactured session (the 223 moduledoc-edit lesson — that gets done inline, never filed). Before filing or splitting, apply the coupling test from `rmap.md` § "Right-size tasks": if task B only deletes/wires/fixes what task A orphans (or A's acceptance criteria already entail B's deliverable), B is the second half of A — fold it in (worked example: the CapabilityScore-delete task collapsed into its parent, whose criteria already said "no magic weights remain"). But do **not** grab-bag — merge only *coupled* smalls (shared files / one orphans the other), never two unrelated smalls just because both are small.
- **Evaluation stays separate — agent vs agent.** Dispatched agent = implementer; a cross-family reviewer AI = grader. Done = reviewer approved, never the implementer's self-report.
- **A reject isn't stop-the-line.** The reviewer fixes what it can inline before deciding; a rejected run puts the task back in the queue for re-dispatch. Manual salvage per `docs/dogfooding-workflow.md` is the fallback when the reviewer rejects.
- **🚨 Under auto-land, check `origin` before calling a task "not landed" — your local checkout is stale.** The lander ff-pushes to `origin/<target>` and **never touches your checkout**, so after an autonomous land your local `tasks.toml` still reads `in_progress` for a task already `done --shipped-in` on origin. **Reading stale local status as "the run didn't land" is the trap** — it provokes a reset-to-`pending` + re-dispatch that *duplicate-lands shipped work*. `git fetch origin <target> && git rebase` (the "Sync development" rule above) — or read `git log origin/<target>` / `result_store-list_run_records` — **before** mutating the roadmap. (Observed 2026-06-12: runs 246/249/251 had landed cleanly; a stale-local misread caused a re-dispatch that double-landed task 246.)
- **🚨 Recover, don't redo — committed work is paid for.** Once you've confirmed against `origin` a run genuinely didn't land: a run that committed to `harness/<run-id>` already cost implementer tokens, and the `ResultStore` record + branch survive teardown. Recover via `dispatch-reland` (approved-unlanded — land-cap/conflict, zero tokens), `dispatch-rereview` (review-stage failure, zero implementer), or `dispatch-resume_failed` (implement-stage, implementer continues). Reset-to-`pending` + fresh dispatch is correct **only** for a run with no committed branch *and* no settled record. Full decision table: `@~/.claude/includes/harness-workflow.md` § "Recover, Don't Redo".
- **Hand-built exceptions:**
  - *Scaffolding that reshapes harness's own runtime* (supervision tree, dep stack, Endpoint) **while the run lifecycle itself is in flux**. A new phase that only adds features on stable surfaces does **not** earn a hand-build window.
  - *Tiny tasks* — ALL of (a) D≤2, (b) ≤30 LOC across ≤3 files, (c) no harness-surface change. Fail any → dispatch. When in doubt, dispatch.
  - *Net-new visual identity with no spec* — exploratory look-and-feel / motion / brand work where distinctiveness is the goal and no design source-of-truth exists yet (the `frontend-design` skill's territory). **Incremental UI/LiveView/heex/CSS work against an existing design system or a frontend-design doc is normal dispatch** — the old blanket "hand-build all UI" rule is retired; an in-repo design spec gives the agent something to build against, so the reviewer AI gates it like any other task.
- **Multi-project autonomy (46/48/51):** dogfooding extends to N registered projects, each with its own `check_command` + `roadmap_path`; with cron enabled it runs unattended.
