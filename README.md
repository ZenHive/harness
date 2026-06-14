# Harness

**OTP-native task-execution engine an AI orchestrator drives end to end.**

Harness pulls tasks from an `rmap` roadmap, dispatches each to a headless coding agent (Claude Code, Cursor, Codex, Grok, Antigravity, Pi) running in an isolated git worktree, then gates the result with a **cross-family reviewer AI** — the reviewer runs the target project's own checks itself, fixes what it can inline, and writes the verdict. The primary user is an AI orchestrator, not a human. The reviewer's verdict — not the implementer's self-report — is the source of truth for success/failure. Every adapter is held to the same `AgentAdapter` behaviour and a reusable conformance suite.

## Status

Harness is a long-running multi-project OTP node. `Harness.ProjectRegistry` holds N first-class projects (Elixir, Rust, anything an agent can check); Oban (queue-per-project, Postgres-persisted) provides dispatch with restart resilience; six agent adapters (Claude Code, Codex, Cursor, Grok, Antigravity, Pi) drive runs; the `Harness.Run` `gen_statem` owns the per-run lifecycle (implement → commit → review → settle); approved runs can auto-land (rebase + ff-push) and get a post-merge audit agent; `Oban.Plugins.Cron` lets the roadmap drive itself unattended. Architecture spec: [docs/agent-gate-workflow.md](docs/agent-gate-workflow.md).

The cold-path consumer surface is the **Phoenix LiveView dashboard** + embedded **Oban Web** + a **native MCP server** (`/harness/mcp`, flat JSON-RPC tools) + a **Tidewave MCP** plug (`/tidewave/mcp`, `project_eval`), all served by one standalone Bandit endpoint on `http://localhost:4018`. The native MCP tools (`dispatch__task`, `dispatch__status`, `dispatch__verdict_detail`, `roadmap__*`, …) are the primary surface for any JSON/MCP orchestrator; Tidewave `project_eval` + IEx are the escape hatch for arbitrary eval and the struct-passing ops the flat tools deliberately omit.

See [ROADMAP.md](ROADMAP.md) for the current task state (rendered from `roadmap/tasks.toml` by `rmap`), [@~/.claude/includes/harness-workflow.md](https://github.com/ZenHive/harness/blob/development/priv/includes/harness-workflow.md) (via `mix harness.install_includes`) for the operator workflow (adopt in any repo), [docs/dogfooding-workflow.md](docs/dogfooding-workflow.md) for harness-incubator specifics, and [skills/harness-driver/SKILL.md](skills/harness-driver/SKILL.md) for the AI-orchestrator contract.

## Running the node

```bash
iex -S mix
```

Boots the OTP application, Postgres-backed Oban, and the standalone dashboard endpoint. Live surfaces:

| URL | What it is |
|---|---|
| `http://localhost:4018/harness` | LiveView dashboard — project switcher, per-bucket run counts, per-run drill-down with live transcript pane |
| `http://localhost:4018/harness/oban` | Oban Web — queue / job rows / retries / scheduled work |
| `http://localhost:4018/harness/mcp` | **Native MCP server** — flat JSON-RPC tools (`dispatch__*`, `roadmap__*`, …); the primary surface for a JSON/MCP orchestrator |
| `http://localhost:4018/tidewave/mcp` | Tidewave MCP endpoint (dev only) — `project_eval` escape hatch for arbitrary eval + struct-surface ops |

The standalone Bandit endpoint is gated by `config :harness, :dashboard, enabled: true` AND `Bandit` being in the dep stack. Mountable consumers (their own Phoenix endpoint) leave `enabled: false` and route `live "/harness/*path", Harness.Dashboard.Live` themselves.

## Use harness from another repo

The common case: you have a project (`myapp`) and want harness — running as a long-lived `iex -S mix` BEAM in `~/_DATA/code/harness/` — to dispatch tasks from `myapp`'s roadmap to headless coding agents, gate each result with a cross-family reviewer AI (which runs `myapp`'s own checks itself), and report the reviewer's verdicts back to the AI agent driving from inside `myapp`.

Three setup steps:

**1. Register `myapp` with harness.** Projects are registered via the live dashboard at `/harness/settings` (preferred for a running node) or via the seed script for fresh/reset DBs. Copy `priv/repo/seeds.exs.example` to `priv/repo/seeds.exs` (gitignored), edit the examples (including the harness self-entry if dogfooding), then run `mix harness.seed` (or `mix ecto.setup` which runs it). The script calls `Harness.ProjectRegistry.upsert/1` which writes Postgres (the source of truth) and wires the Oban queue. For ad-hoc use IEx or the MCP `dispatch-register_project` tool.

`check_command` (in the seed or dashboard form) is a free-text hint handed to the reviewer AI — the reviewer runs the project's checks itself and judges the output; harness never executes the command. Point it at your project's mergeable bar (`mix precommit`, `cargo test && cargo clippy`, …); for a multi-language monorepo just describe each component's command in the hint. Omit it to let the reviewer discover the checks on its own.

**2. Add harness's MCP endpoints to `myapp/.mcp.json`** — alongside `myapp`'s own Tidewave if it has one. The `harness` entry (native flat tools) is your primary surface; the optional `harness_eval` entry is the `project_eval` escape hatch into harness's BEAM:

```json
{
  "mcpServers": {
    "tidewave": {
      "type": "http",
      "url": "http://localhost:4001/tidewave/mcp"
    },
    "harness": {
      "type": "http",
      "url": "http://localhost:4018/harness/mcp"
    },
    "harness_eval": {
      "type": "http",
      "url": "http://localhost:4018/tidewave/mcp"
    }
  }
}
```

Claude Code surfaces a server's tools as `mcp__<server-name>__<tool>`, giving three distinguishable surfaces: `mcp__tidewave__project_eval` (inspect `myapp`'s state, port 4001), `mcp__harness__dispatch__task` & the rest of the flat driver tools (dispatch + observe + triage against harness's `:4018` BEAM — **the primary surface**), and `mcp__harness_eval__project_eval` (escape hatch for arbitrary eval + struct-surface ops). Drop `harness_eval` if you only need the flat tools. No port collision — different BEAMs / paths.

**3. Import the driver skill from `myapp/CLAUDE.md`** so the AI agent in `myapp` knows how to use the surface:

```
@~/_DATA/code/harness/skills/harness-driver/SKILL.md
```

Restart the Claude Code session in `myapp` to pick up the new `.mcp.json` entries. After that, the agent dispatches via the flat `mcp__harness__dispatch__task` tool (and observes with `mcp__harness__dispatch__status` / `dispatch__verdict_detail`) against `:4018`; harness manages isolated worktrees of `myapp`, gates each run with the cross-family reviewer AI, and reports the reviewer's verdict back.

Full driver contract (entry points, two-eval pattern for ephemeral MCP eval processes, cross-checkout sharp edges, secret scrubbing): [skills/harness-driver/SKILL.md](skills/harness-driver/SKILL.md) § "Context A — Driving harness from another repo".

## Development

```bash
# First time
mix deps.get
mix compile

# Fast local gate (hook-bound, ~180s)
mix check.fast

# Pre-commit gate (no dialyzer — dialyzer lives in precommit.full)
mix precommit

# Full hand-off gate — mirrors CI, includes dialyzer
mix precommit.full

# Focused checks
mix test
mix credo --strict        # includes TODO/FIXME debt visibility by design
mix sobelow --exit --skip
mix sobelow.baseline      # refresh Sobelow skip baseline intentionally

# AI-friendly output
mix test.json
mix dialyzer.json
```

All tooling is wired per the global Elixir setup conventions (Styler first, Reach for OTP analysis, etc.).

## License

MIT (or your preferred license).
