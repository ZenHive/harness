# Agent CLI Reference — Headless Adapter Surface

The per-agent headless-CLI facts the `AgentAdapter` implementations (Tasks 4, 13, 14, 15)
and the rule-injection task (Task 22) are built against. One verified source so each
adapter task consumes it instead of re-researching.

**Snapshot: 2026-05-20.** These CLIs ship frequently (the harness `CLAUDE.md` notes 40+
releases each). Re-verify the relevant agent's flags from its docs before implementing
that adapter — treat this file as a starting point, not a frozen contract.

## Five-fact summary

| Fact | Claude Code | Codex | Cursor | Grok | Antigravity |
|---|---|---|---|---|---|
| Headless invocation | `claude -p` / `--print` | `codex exec` (`codex e`) | `cursor-agent -p` / `--print` | `grok -p` / `--single` | `agy -p` |
| Raw output format | `--output-format text\|json\|stream-json` | `--json` / `--experimental-json` (NDJSON) | `--output-format text\|json\|stream-json` | `--output-format plain\|json\|streaming-json` | none (plain text) |
| System-prompt channel | **`--append-system-prompt[-file]`** (append) · `--system-prompt[-file]` (replace) | **none** — `AGENTS.md` file is the native mechanism | **none** — no inline flag | **none** documented | **none** |
| Session resume | `--resume`/`-r <id\|name>` · `--continue`/`-c` · `--fork-session` | `codex exec resume [ID]` · `--last` · `--all` | `--resume [chatId]` · `--continue` | `-s`/`--session-id` · `-r`/`--resume` · `-c`/`--continue` | `--continue` |
| Working dir / approval | `--add-dir` · `--permission-mode default\|acceptEdits\|plan\|auto\|dontAsk\|bypassPermissions` | `--cd`/`-C` · `--sandbox read-only\|workspace-write\|danger-full-access` · `--ask-for-approval untrusted\|on-request\|never` | `--workspace` · `-f`/`--force` · `--yolo` · `--trust` (headless) | `--cwd` · `--always-approve` | `--dangerously-skip-permissions` |

## Ingestion and Prompt Rendering Contract

`rmap delegate --to` renders a native prompt for every adapter harness ships — `Claude Code`, `Codex`, `Cursor`, `Grok`, `Antigravity`, and `Pi`. The harness ingestion surface (`Harness.Roadmap.ingest/2`) accepts all six as `:agent` values and dispatches each directly on its own adapter module; there is no claude-rendered two-step.

`rmap` can also render a `droid` prompt, but harness ships **no Droid adapter**, so `:droid` is rejected at the ingest boundary (`{:invalid_agent, :droid}`) and at flat dispatch (`{:unknown_adapter, "droid"}`) — there is no executor to run it. Adding an executor is two-sided: a `rmap delegate --to` target (the rmap binary is ours, `../rmap/`; the `droid` render target already exists) **plus** a harness `AgentAdapter` added to `Harness.Roadmap`'s `@valid_agents` and `Harness.AgentAdapter.Registry`.

(Worktree isolation is an orthogonal axis: all six shipped adapters currently declare `worktree_isolation: true`. Antigravity's Task 32 finding is stale as of `agy` 1.0.5; a 2026-06-04 linked-worktree re-test showed `agy` honoring the Port `cwd`.)

## Per-agent detail

### Claude Code
- Headless: `-p` / `--print`. Output: `--output-format text|json|stream-json`; pair with
  `--input-format stream-json`, `--include-partial-messages`, `--include-hook-events`.
- **System prompt — four flags.** `--append-system-prompt <text>` and
  `--append-system-prompt-file <path>` append to the default prompt (Claude stays a
  coding assistant + your extra rules). `--system-prompt[-file]` *replaces* the whole
  default prompt — drops tool guidance and safety instructions; not what the harness wants.
  Append flags can combine with replace flags.
- `--exclude-dynamic-system-prompt-sections` — moves per-machine sections (cwd, env,
  memory paths) into the first user message to improve **prompt-cache reuse across
  scripted multi-run workloads**. Designed for exactly the harness's `-p` fan-out.
- Resume: `--resume`/`-r` (by id or `--name`), `--continue`/`-c`, `--fork-session`.
- The docs explicitly say: persistent project conventions → `CLAUDE.md`; per-invocation
  extra rules for a `-p` script → an append flag. That is the harness's split exactly.

### Codex
- Headless: `codex exec` / `codex e`. Prompt is positional, or `-` to read stdin.
- Output: `--json` / `--experimental-json` (NDJSON, one event per state change).
- **No `--system-prompt` flag.** Codex's native persistent-instruction mechanism is an
  `AGENTS.md` file in the workspace root. `-c`/`--config key=value` (repeatable) sets
  inline config overrides — no documented key for base instructions surfaced.
- Resume: `codex exec resume [SESSION_ID]`, `--last`, `--all`.
- cwd `--cd`/`-C`; sandbox `--sandbox`, approval `--ask-for-approval`,
  `--dangerously-bypass-approvals-and-sandbox`/`--yolo`, `--full-auto` (deprecated).

### Cursor
- Headless: `-p` / `--print` ("access to all tools, including write and shell").
- Output: `--output-format text|json|stream-json` (reference says default `text` — use
  `stream-json` for headless); `--stream-partial-output` for text deltas.
- **No inline system-prompt flag.** Only a `generate-rule` command that creates rule
  files interactively — not a CLI parameter.
- Resume: `--resume [chatId]`, `--continue` (alias for `--resume=-1`).
- `--workspace <path>`; `-f`/`--force` (alias `--yolo`), `--trust` (headless-only),
  `--approve-mcps`.

### Grok
- Headless: `-p` / `--single <PROMPT>`.
- Output: `--output-format plain|json|streaming-json` (`streaming-json` = NDLJSON events).
- **No system-prompt flag documented.**
- Resume: `-s`/`--session-id`, `-r`/`--resume`, `-c`/`--continue`.
- `--cwd <path>`; `--always-approve` auto-approves tool executions.
- `grok agent stdio` runs Grok as a JSON-RPC (ACP) agent over stdin/stdout — an
  alternative transport, relevant to the deferred ACP adapter (Task 21).

### Antigravity
- Headless: `-p`.
- Output: Standard output (plain text).
- **No system-prompt flag.**
- Resume: `--continue`.
- `--dangerously-skip-permissions` auto-approves operations and skips permission prompts.

## System-prompt injection verdict (for Task 22)

The research **confirms** Task 22's central assumption: only Claude Code has a dedicated
system-prompt append channel; Codex, Cursor, and Grok have none. The plan ("dedicated
channel where it exists, prompt-prepend otherwise") holds — with two refinements:

1. **Claude — prefer `--append-system-prompt-file`** over the inline `--append-system-prompt`.
   A file path avoids a multi-KB shell argument and arg-length limits, and the appended
   system prompt sits in a prompt-cacheable slot — pair with
   `--exclude-dynamic-system-prompt-sections` so a repair loop's repeated invocations
   reuse the cache.

2. **Codex / Cursor have a native rule *file* mechanism** (`AGENTS.md`; Cursor rule
   files). For these, a harness-generated **ephemeral** rule file written into the
   throwaway worktree — regenerated from the single canonical source each run, never
   committed, discarded with the worktree — is a third option alongside prompt-prepend.
   That is *not* "bloating committed `AGENTS.md`s" (the maintenance cost Task 22 targets);
   it is the same render-from-canonical-source pattern, file-delivered because the CLI
   offers no flag. Grok and Antigravity have neither a flag nor a documented rule file →
   prompt-prepend is the only channel.

Cost note: for any prompt-prepended agent the rule preamble is re-sent (and re-paid) on
every invocation — a repair loop pays it N times. This is why Task 22's injected set must
be a curated subset, not the full includes corpus.

## Known cross-agent gotcha

Headless **exit codes are unreliable** across all five (already noted in `CLAUDE.md`).
Derive *termination* from the process/Port closing plus a timeout guard; derive *success*
from the harness verification stack — never from `$?`.

## Sources

- Grok — https://docs.x.ai/build/cli/headless-scripting
- Claude Code — https://code.claude.com/docs/en/cli-reference
- Codex — https://developers.openai.com/codex/cli/reference
- Cursor — https://cursor.com/docs/cli/reference/parameters , https://cursor.com/docs/cli/headless
- Antigravity — https://docs.antigravity.ai/cli/headless
