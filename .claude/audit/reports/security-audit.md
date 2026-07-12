# Security Audit: harness

Scope: OTP-native agent-orchestration engine (Port-spawned CLI agents, git worktree/lander mechanics, Phoenix LiveView dashboard + MCP server on :4018). Read/Grep-only audit (no Bash) plus manual triage of `.sobelow-skips`.

## Executive Summary

No injectable command/SQL vulnerabilities were found in the reviewed surfaces — the Port-spawning design (`/bin/sh -c 'exec "$0" "$@" </dev/null' <agent> <argv...>`) is genuinely injection-safe because the executable and args ride as positional shell parameters, never interpolated into a shell string; git operations use `System.cmd`/argv lists with `-C <repo>`; Ecto fragments use `?` placeholders throughout. The large `.sobelow-skips` baseline was spot-checked and the sampled findings (System command injection, atom exhaustion, file traversal) are legitimate false positives — fixed binaries/argv or operator/DB-controlled paths, not web/user input.

The one design-level finding worth operator attention is that the dashboard, Oban Web UI, and MCP JSON-RPC server carry **zero authentication or authorization** — mitigated today only by the hardcoded loopback bind, not by any access control in the code itself.

## Findings

### 1. Dashboard + MCP server have no authentication/authorization layer
- **Severity**: Medium (Low as currently deployed; escalates to Critical if ever bound beyond loopback or mounted into a consumer's public-facing endpoint)
- **Location**: `lib/harness/dashboard/endpoint.ex` (no auth plug in the pipeline), `lib/harness/dashboard/router.ex` (all `/harness/*` LiveViews + `/harness/oban` + `/harness/mcp` forward with no auth requirement), `lib/harness/dashboard/mcp_server.ex:56-58` — comment explicitly states *"we configure no MCP authorization"*.
- **Issue**: Any client that can reach the endpoint gets full unauthenticated control: dispatch tasks to any registered project, kill in-flight runs, browse run transcripts (which may contain agent reasoning/diffs/secrets-adjacent output), read/mutate settings, and call the entire `Harness.Manifest`-derived MCP tool surface (`dispatch-*`, `model_availability-*`, project registry mutation, etc.) via `/harness/mcp`. The `:browser` pipeline does add `protect_from_forgery` + `put_secure_browser_headers`, but that only covers the LiveView scope — the MCP forward (`router.ex:30-33`) sits outside `:browser` entirely, with no auth of any kind.
- **Mitigating factor observed**: `config/config.exs:9` and `config/runtime.exs:33-37` hardcode `ip: {127, 0, 0, 1}` even when `HARNESS_DASHBOARD_PORT` relocates the port — so today's default deployment is loopback-only. The `@moduledoc` for `Endpoint` also documents mountable consumers replicating these routes into their *own* Phoenix endpoint — at that point the auth gap becomes the consuming app's problem, silently, unless it adds its own plug.
- **Fix**: Add an explicit auth plug (token/basic-auth via `HARNESS_DASHBOARD_TOKEN` env var, or Plug.BasicAuth) in front of both the `:browser` pipeline and the `/harness/mcp` forward, at minimum gated behind a config flag for non-loopback binds; document the requirement prominently for mountable consumers embedding the router into a public endpoint.

### 2. `:erlang.binary_to_term/1` without `:safe` on stored payloads
- **Severity**: Low (defense-in-depth; not remotely triggerable through any surface found in this audit)
- **Location**: `lib/harness/result_store/postgres.ex:714`, `lib/harness/settings_store/postgres.ex:71`, `lib/harness/project_registry/persistence.ex:232` (all three flagged and skipped in `.sobelow-skips` as `Misc.BinToTerm`).
- **Issue**: These decode binary columns harness itself wrote via `:erlang.term_to_binary` — not attacker-reachable under the current threat model — but `binary_to_term/1` (no `[:safe]` option) will materialize arbitrary atoms/funs/refs from any bytes handed to it. If Postgres write access is ever available to a lower-trust actor (e.g. a compromised dependent service sharing the DB, or a future feature that lets an agent write these tables), this becomes a code-shaped decode path rather than pure data.
- **Fix**: Add `[:safe]` to all three call sites (`:erlang.binary_to_term(payload, [:safe])`); the existing `rescue ArgumentError -> {:error, :invalid_term}` already handles the decode-failure path, so this is a same-shape change with no behavioral risk to the happy path.

## Verified Clean (spot-checked, not exhaustive)

- Port spawning (`lib/harness/agent_adapter.ex`): exec via positional `$0`/`$@` — no shell word-splitting/injection surface for prompts, model ids, or paths.
- Git subprocess wrapper (`lib/harness/git.ex`) and lander (`lib/harness/lander.ex`): all argv-list `System.cmd`/`Git.run`, no string-built shell commands; branch/target names ride as discrete argv entries.
- Secrets: `ANTHROPIC_API_KEY`/`OPENAI_API_KEY` scrubbed from spawned-agent env via unset (`scrub_auth_env/2`), never logged; `secret_key_base` sourced from `HARNESS_SECRET_KEY_BASE` in `runtime.exs`, hardcoded default explicitly documented as loopback-only dev fallback; DB credentials from env vars.
- Ecto: every `fragment(...)` call site found uses `?` placeholders with `^`-pinned or literal values — no string interpolation into SQL.
- Atom safety: all `String.to_atom`/atomization call sites reviewed (`chat/tools.ex`, `roadmap.ex`, `dep_freshness/provider/javascript.ex`) use `String.to_existing_atom/1` wrapped in `rescue ArgumentError` — no unbounded atom creation from external input.
- `.sobelow-skips` sampled entries (System command injection in `model_availability.ex`, `dep_freshness/provider/{javascript,rust}.ex`; SQL.Query in `code_search.ex`; file traversal across `worktree.ex`/`lander.ex`) — all confirmed fixed-binary/argv-list commands or operator/DB-controlled paths, matching the documented false-positive class in the task prompt.
- Worktree path construction (`worktree.ex:196-211`) uses an internally-generated run `id` (`generate_id/0`), not attacker- or roadmap-controlled task ids, so no path-traversal vector via `Path.join([base_dir, project.name, id])` was found in the reviewed create path.
- No `raw/1` / `Phoenix.HTML.raw` usage found anywhere in `lib/`.

## Recommendations (priority order)

1. Add auth (even minimal shared-secret/basic-auth) in front of the dashboard + MCP endpoint, config-gated for non-loopback binds, and call it out explicitly in the mountable-consumer docs.
2. Add `[:safe]` to the three `binary_to_term/1` call sites.
3. Periodically re-validate the `.sobelow-skips` baseline stays false-positive-only as new call sites are added (the file states it's audit-review-regenerated — keep that discipline).

## Tools to Recommend

- `mix sobelow --exit medium` (note: `.sobelow-skips` baseline already covers ~200 documented false positives — run `--skip` to see genuinely new findings only)
- `mix deps.audit`
- `mix hex.audit`
