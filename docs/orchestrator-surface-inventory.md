# Orchestrator Surface Inventory (Task 184)

**What this is.** The descripex `api()`-annotated driver surface harness exposes to an AI
orchestrator, inventoried against what an orchestrator actually wants callable, with the
gap called out. Produced *before* any annotation work (Task 184 step 1), then used to
scope the read/observe and write additions (steps 2–3).

**The three surfaces are one source.** `Harness.Manifest` curates `@driver_surface`
modules; `Descripex.MCP.tools/2` renders their `api()` functions as MCP tools;
`Harness.Manifest.mcp_tools/1` drops any tool with an `:exchange_data` param (a struct a
stateless JSON caller cannot construct). Both consumer surfaces — the in-process
`Harness.Chat.Tools` registry and the external `Harness.Dashboard.MCPServer` — resolve
that *same* filtered list. **Consequence: annotating a function on a curated module
surfaces it in BOTH the chat dispatcher and the MCP server simultaneously, with zero glue
code.** No edit to `chat/tools.ex` or `mcp_server.ex` is needed for a new tool — they are
generic over the Manifest. (This is why Task 184's "files to modify" hint listing them was
speculative; the design makes them no-op.)

---

## 1. Current JSON-reachable surface (what an orchestrator can self-serve)

Reachable over MCP/chat (JSON scalars only). Grouped by orchestrator intent.

### Read / observe

| Tool | Backs | Intent |
|---|---|---|
| `roadmap-list` / `roadmap-ready` / `roadmap-next_bundle` | `Harness.Roadmap` | Browse a project's roadmap as structured data; parallel-safe dispatch set; next bundle |
| `roadmap-ingest` | `Harness.Roadmap.ingest/2` | Render a task as a ready-to-dispatch prompt |
| `dispatch-status` | `Harness.Run.status/1` (flat) | Live/queued run lifecycle snapshot + reviewer verdict-so-far |
| `dispatch-transcript` / `dispatch-transcript_events` | `Harness.Run` (flat) | Buffered raw / parsed transcript of a live run, with `seq` delta polling |
| `dispatch-verdict_detail` | `Harness.ResultStore` | Settled-run reviewer verdict / report / ratings |
| `result_store-list_run_records` | `Harness.ResultStore` | Settled run records (verdict, diff sizes, token usage, transcript) |
| `routing-brief` | `Harness.Routing` | **Thin task-writer routing index**: dispatchable roster + availability + KPI rollups per `{agent, model}` by default, with opt-in full catalog / agent filter / pair-field projection and no ranking |
| `result_store-aggregate_by_agent` | `Harness.ResultStore` → `Harness.AgentKPI` | **Per-agent KPI rollup** (success, first-attempt-pass, duration p90, cost-to-green) |
| `result_store-aggregate_ceremony_cost` | `Harness.ResultStore` → `Harness.AgentKPI` | **Per-approved-run ceremony token facts** (implementer + reviewer + audit=0; median/p90 distribution over raw per-run totals — no batching verdict) |
| `dispatch-recommend` | `Harness.Dispatch.recommend/2` + `Harness.CapabilityScore.recommend/2` | Per-facet scout assessment match: returns scout's winner + reasoning for the task's `review_facets` (`:exploit`), or `:explore`/fallback when unmeasured or no assessment yet. `dispatch-assess_facets` triggers a fresh scout pass. |
| `project_registry-list` / `project_registry-lookup` | `Harness.ProjectRegistry` | Discover registered projects + config |
| `agents-list` / `agents-reviewers` | `Harness.Agents` | Read installed/available/enabled agent facts, reviewer eligibility, configured model pins, and the ordered reviewer slate |
| `autonomy-status` | `Harness.Autonomy` | Read cron autonomy master/project toggles, dispatch mode, effective state, and schedule presets |
| `config-list` / `config-get` | `Harness.Config` | Read operator config schema entries and effective values; secret values are redacted |
| `describe-tools` / `describe-tool` | `Harness.Describe` | Self-describe the live MCP tool catalog and one tool's params/returns schema |
| `playbooks-list` / `playbooks-get` | `Harness.Playbooks` | Orchestration recipes |

### Write / control

| Tool | Backs | Intent |
|---|---|---|
| `dispatch-task` / `dispatch-await` | `Harness.Dispatch` | Dispatch one task (fire-and-forget / blocking-with-verdict) |
| `dispatch-bundle` / `dispatch-compare` | `Harness.Dispatch` | Fan out a bundle / same-task A/B across adapters |
| `dispatch-cancel` | `Harness.Run.cancel/1` (flat) | Kill an in-flight run (idempotent) |
| `roadmap-mark_landed` / `roadmap-mark_blocked` / `roadmap-mark_in_progress` / `roadmap-mark_pending` | `Harness.Roadmap` | Write a run's outcome back to the roadmap |
| `project_registry-unregister` | `Harness.ProjectRegistry` | Drop a runtime registration |
| `audit_review-grade_fix` | `Harness.AuditReview` | Cross-agent HIGH-tier grade of one commit |
| `dispatch-pending` / `dispatch-approve` | `Harness.Dispatch` | List / approve parked autonomous (cron) dispatch decisions for `:manual` mode projects (Task 237) |

### In-process only (`:exchange_data` — filtered from JSON, reached via `project_eval`/IEx)

`supervisor-start_run`, `batch-run` / `batch-run_pinned` / `batch-dispatch`,
`agent_evaluation-compare`, and the struct-handle `Harness.Run.{status,transcript,…}`
functions (the flat `dispatch-*` wrappers are their JSON path). These take `%Item{}` /
`%Project{}` / pid handles a JSON caller cannot construct, and stay on the full Elixir
driver surface (`Harness.Manifest.build/0` / `modules/0`).

---

## 2. Orchestrator-desired set vs. the gap

The desired set (from the task): roadmap browse · run status/transcript · AgentKPI +
scout routing facts · project/registry listing (read); dispatch · cancel ·
hold/steer/resume · project registration (write).

| Desired | Status before Task 184 | Gap |
|---|---|---|
| Roadmap browse | ✅ `roadmap-list/ready/next_bundle` | none |
| Run status / transcript | ✅ `dispatch-status/transcript/transcript_events` | none |
| AgentKPI rollups | ✅ `result_store-aggregate_by_agent` (per-agent), `result_store-aggregate_ceremony_cost` (per-approved-run ceremony/implementer+reviewer+audit token overhead) | none |
| Capability (scout) routing | ✅ `dispatch-recommend` + `dispatch-assess_facets` (scout per-facet assessment) | none |
| Task-writer assignee/model routing facts | ✅ `routing-brief` joins roster, availability/blocks, and KPI rollups per `{agent, model}` as a thin dispatchable-only index by default | none |
| Project / registry listing | ✅ `project_registry-list/lookup` | none |
| Operator agent/reviewer state | ✅ `agents-list` / `agents-reviewers` | none |
| Cron autonomy state | ✅ `autonomy-status` | none |
| Operator config state | ✅ `config-list` / `config-get` | none |
| Self-description for non-tools/list drivers | ✅ `describe-tools` / `describe-tool` | none |
| Dispatch | ✅ `dispatch-task/await/bundle/compare` | none |
| Cancel | ✅ `dispatch-cancel` | none |
| **Hold / steer / resume** | ❌ annotated on `Harness.Run` but `:exchange_data`-filtered; **no flat JSON tool** | **GAP** |
| **Project registration** | ⚠️ `project_registry-register` annotated `:value` but takes a `%Project{}` — **broken over JSON** (struct guard fails, surfaces as `dispatch_failed`) | **GAP** |

**Task 262 update:** operator read-state is now complete too. `agents-*`,
`autonomy-status`, `config-*`, and `describe-*` expose mechanical facts only — installed?,
enabled?, reviewer_eligible?, config values, cron toggles, and live schema metadata. They
do not compute a best reviewer, score, route, or verdict.

**Task 266 update:** `routing-brief` is now THE single MCP/chat fact source for a
task-writer deciding `assignee` + `model`. It exists so orchestrators do not read
`lib/harness/*.ex` or call three separate tools just to route a task. The brief is the raw
facts layer beneath `dispatch-recommend`: it joins roster, availability/block annotations,
and KPI rollups per `{agent, model}`, with `n` on measured KPI cells and `n: 0` /
`explore_candidate: true` on cold-start KPI cells. It returns no best pick, ranking,
weighted score, or route verdict.

**Task 273 update:** `routing-brief` is the thin list surface, not the detail surface. By
default it returns only pairs whose agent is installed, enabled, and currently available,
and whose model pair is unblocked/available. Pass `include_all: true` only when you
need the verbose full catalog, `agents: ["codex", "cursor"]` to narrow by agent, and
`fields: ["agent", "model", "availability", "kpi"]` to project pair keys. For
per-agent depth, drill into the existing aggregate lenses:
`result_store-aggregate_by_agent`, `result_store-aggregate_by_facet`,
`result_store-aggregate_reviewer_reliability`, and
`result_store-aggregate_ceremony_cost`. Do not add new KPI tools for detail those lenses
already provide.

---

## 3. Changes made (Task 184 steps 2–3)

Read/observe (step 2): **no code change** — surface already complete (see §2).

Write subset (step 3): four new flat, JSON-native tools, each a thin mechanical wrapper.
Rationale per tool (the "deliberate, not blanket" requirement):

| New tool | Backs | One-line rationale |
|---|---|---|
| `dispatch-hold` | `Harness.Run.hold/2` | Park a run for operator-mediated recovery — a real autonomous-orchestrator action when a run goes sideways; mechanical `:running → :held` transition. |
| `dispatch-steer` | `Harness.Run.steer/2` | Stash guidance for the next agent boundary — lets the orchestrator correct course without killing the worktree; records a note, does not judge. |
| `dispatch-resume` | `Harness.Run.resume/1` | Resume a held run in the same worktree — the other half of hold; mechanical `:held → :running`. |
| `dispatch-register_project` | `Harness.ProjectRegistry.register/1` (via the validated builder) | Register a project for dispatch from JSON scalars — the directly-requested ability to onboard a target without a human in IEx; assembles the struct through the same validator/path-expansion as a config entry. |
| `agents-list` / `agents-reviewers` | `Harness.Agents` | Read operator agent/reviewer facts without grep or `project_eval`; reviewer slate reuses the run's mechanical eligibility/order helpers. |
| `autonomy-status` | `Harness.Autonomy` | Read the cron autonomy switches and effective per-project state through the same settings registry the poller uses. |
| `config-list` / `config-get` | `Harness.Config` | Read config schema/effective values over MCP with secret redaction. |
| `describe-tools` / `describe-tool` | `Harness.Describe` | Let chat/project_eval drivers self-describe the live tool catalog when protocol-level `tools/list` is unavailable. |

Plumbing: `Harness.ProjectRegistry.register/1`'s `project` param was re-marked
`:exchange_data` (it genuinely takes a struct), which removes the broken
`project_registry-register` from the JSON surface. A keyword/map `register/1` clause was
added so `dispatch-register_project` routes through the existing `build_project/1`
validator instead of duplicating field logic.

---

## 4. Intentional omissions (what was deliberately NOT exposed, and why)

- **`project_registry-register` (struct form)** — removed from the JSON surface; a stateless
  caller cannot build a `%Project{}`. Use `dispatch-register_project` (JSON) or the struct
  path via `project_eval` (in-process). Strictly better than the prior broken exposure.
- **Project struct fields `landing_policy` / `target_branch` / `pollution_allowlist`** — not
  parameters of `dispatch-register_project`. `landing_policy` defaults to `:manual` (no
  surprise auto-land from an autonomous registration); the rare cases that need auto-landing
  or a pollution allowlist register via `config :harness, :projects` or the struct path.
  Keeps the flat tool's schema small (context-budget) while covering the common shape.
- **Runtime registration is not durable** unless `:repo_enabled` — documented on the tool;
  durable registration stays config-file + restart, per the harness-driver skill.
- **`batch-*` / `supervisor-start_run` / `agent_evaluation-compare`** — stay in-process
  (`:exchange_data`); the flat `dispatch-bundle` / `dispatch-task` / `dispatch-compare`
  tools are their JSON-native counterparts. No new struct tools added to the JSON surface.
- **Per-`{agent, domain}` KPI slicing** (`AgentKPI.aggregate_by_agent_domain/1`) — not
  exposed; `result_store-aggregate_by_agent` covers the per-agent rollup, and the
  orchestrator can slice `result_store-list_run_records` itself. Left for a later task if
  per-domain demand surfaces.

---

## 5. Guardrail confirmations

**No `api()` returns a judgment (AC4).** Every newly-exposed function is mechanical:
hold/steer/resume are gen_statem lifecycle transitions; register_project assembles and
stores a struct. None decides is-this-done / is-this-good / whose-fault / should-this-merge
— those remain the reviewer AI's job, surfaced (not computed) via `dispatch-verdict_detail`.
`routing-brief` follows the same rule for routing: it joins facts and sample counts only;
`dispatch-recommend` remains the separate advisory layer when an AI-written pick is wanted.

**In-run agents get no harness-control surface (AC6).** The harness MCP server
(`/harness/mcp`) is wired only into orchestrator contexts — the chat backend
(`Harness.Chat.Claude` writes `.harness-mcp-config.json` for *itself*) and consuming repos'
`.mcp.json`. The implementer/reviewer adapters spawned inside a target-project worktree
receive their rules via `Harness.AgentAdapter.attach_rules/2` and run against the *target*
project's own tooling — harness never injects its control MCP config into them. This task
changed no adapter, rule-channel, or dispatch path, so that isolation is unchanged: an
agent implementing a task still cannot cancel/steer/dispatch harness runs.
