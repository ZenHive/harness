# Harness

**OTP-native task-execution engine an AI orchestrator drives end to end.**

Harness pulls tasks from an `rmap` roadmap, dispatches each to a headless coding agent (Claude Code, Cursor, Codex, Grok) running in an isolated git worktree, runs the target project's own check stack against the result, and reports a *verified* outcome back over an agent-shaped surface (MCP tools + JSON CLI).

The primary user is an AI orchestrator, not a human. The verification stack — not the agent's self-report — is the source of truth for success/failure. Every adapter is held to the same `AgentAdapter` behaviour and a reusable conformance suite.

## Status

Early development. The core loop is taking shape — rmap task ingestion, the
per-run worktree lifecycle, the verification runner, the `AgentAdapter`
behaviour with its reusable conformance suite, and four concrete adapters
(Claude Code, Codex, Cursor, and Grok, with a generic timeout-enforcing run
driver) are in place.

See [ROADMAP.md](ROADMAP.md) for the full plan and current task status
(rendered from `roadmap/tasks.toml` by `rmap`).

## Development

```bash
# First time
mix deps.get
mix compile

# Typical loop
mix test
mix credo --strict
mix dialyzer
mix doctor
mix sobelow --exit Low

# With AI-friendly output
mix test.json
mix dialyzer.json

# Dev MCP surface (Tidewave on port 4016)
iex -S mix tidewave
```

All tooling is wired per the global Elixir setup conventions (Styler first, Reach for OTP analysis, etc.).

## License

MIT (or your preferred license).

