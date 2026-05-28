# Harness

**OTP-native task-execution engine an AI orchestrator drives end to end.**

Harness pulls tasks from an `rmap` roadmap, dispatches each to a headless coding agent (Claude Code, Cursor, Codex, Grok, Antigravity, Pi) running in an isolated git worktree, runs the target project's own check stack against the result, and reports a *verified* outcome. The primary user is an AI orchestrator, not a human. The verification stack — not the agent's self-report — is the source of truth for success/failure. Every adapter is held to the same `AgentAdapter` behaviour and a reusable conformance suite.

## Status

Post-v0_5: harness is a long-running multi-project OTP node. `Harness.ProjectRegistry` holds N first-class projects (Elixir, Rust, anything with a shell-driven check stack); Oban (queue-per-project, Postgres-persisted) provides dispatch with restart resilience; six agent adapters (Claude Code, Codex, Cursor, Grok, Antigravity, Pi) drive runs; the `Harness.Run` `gen_statem` owns the per-run lifecycle and an autonomous repair loop; `Oban.Plugins.Cron` lets the roadmap drive itself unattended.

The cold-path consumer surface is the **Phoenix LiveView dashboard** + embedded **Oban Web** + the **Tidewave MCP** plug, all served by one standalone Bandit endpoint on `http://localhost:4018`. Tidewave + IEx + the dashboard ARE the agent surface for the Elixir-native consumer; MCP/JSON CLI (Task 17) remains **deferred** until a non-BEAM consumer needs it.

See [ROADMAP.md](ROADMAP.md) for the current task state (rendered from `roadmap/tasks.toml` by `rmap`), [docs/dogfooding-workflow.md](docs/dogfooding-workflow.md) for the operator runbook, and [skills/harness-driver/SKILL.md](skills/harness-driver/SKILL.md) for the AI-orchestrator contract.

## Running the node

```bash
iex -S mix
```

Boots the OTP application, Postgres-backed Oban, and the standalone dashboard endpoint. Live surfaces:

| URL | What it is |
|---|---|
| `http://localhost:4018/harness` | LiveView dashboard — project switcher, per-bucket run counts, per-run drill-down with live transcript pane |
| `http://localhost:4018/harness/oban` | Oban Web — queue / job rows / retries / scheduled work |
| `http://localhost:4018/tidewave/mcp` | Tidewave MCP endpoint (dev only) — for IEx-style `project_eval` and tool dispatch |

The standalone Bandit endpoint is gated by `config :harness, :dashboard, enabled: true` AND `Bandit` being in the dep stack. Mountable consumers (their own Phoenix endpoint) leave `enabled: false` and route `live "/harness/*path", Harness.Dashboard.Live` themselves.

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
