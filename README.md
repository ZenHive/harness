# Harness

**OTP-native task-execution engine an AI orchestrator drives end to end.**

Harness pulls tasks from an `rmap` roadmap, dispatches each to a headless coding agent (Claude Code, Cursor, Codex, Grok, Antigravity, Pi) running in an isolated git worktree, runs the target project's own check stack against the result, and reports a *verified* outcome back over an Elixir API suited for IEx/Tidewave orchestration. Oban-backed persisted dispatch is landing as the multi-project queue layer; MCP/JSON CLI remains deferred until an external non-BEAM consumer needs it.

The primary user is an AI orchestrator, not a human. The verification stack — not the agent's self-report — is the source of truth for success/failure. Every adapter is held to the same `AgentAdapter` behaviour and a reusable conformance suite.

## Status

Early development. The core loop is taking shape — rmap task ingestion, the
per-run worktree lifecycle, the verification runner, the `AgentAdapter`
behaviour with its reusable conformance suite, six concrete adapters (Claude
Code, Codex, Cursor, Grok, Antigravity, and Pi), a generic timeout-enforcing run
driver, and Oban-backed dispatch scaffolding are in place.

See [ROADMAP.md](ROADMAP.md) for the full plan and current task status
(rendered from `roadmap/tasks.toml` by `rmap`).

## Development

```bash
# First time
mix deps.get
mix compile

# Fast local gate
mix check.fast

# Full hand-off gate
mix precommit

# Focused checks
mix test
mix credo --strict        # includes TODO/FIXME debt visibility by design
mix sobelow --exit --skip
mix sobelow.baseline      # refresh Sobelow skip baseline intentionally

# With AI-friendly output
mix test.json
mix dialyzer.json

# Dev MCP surface (Tidewave on port 4016)
iex -S mix tidewave
```

All tooling is wired per the global Elixir setup conventions (Styler first, Reach for OTP analysis, etc.).

## License

MIT (or your preferred license).
