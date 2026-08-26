# HarnessAgentAdapter

[![License](https://img.shields.io/github/license/ZenHive/harness_agent_adapter.svg)](https://github.com/ZenHive/harness_agent_adapter/blob/main/LICENSE)

The `Harness.AgentAdapter` behaviour plus six adapters for headless
coding-agent CLIs — Claude Code, Cursor, Codex, Grok, Antigravity, and Pi —
all driven over OTP Ports. No per-agent SDK, no output normalization: an
adapter builds the agent's headless command line, spawns it, classifies the
port's messages as raw output / termination / failure, and can kill an
in-flight run. It does not parse the agent's output.

## Why

Every one of these CLIs ships its own JSON-ish transcript shape and revises
it across releases. A normalization layer chases that churn forever and
still loses information the consumer wanted. This package's adapters pass
raw output straight through — the consumer is expected to be an AI that
reads a transcript natively, not a program pattern-matching on a schema.
What stays code is mechanical: spawn the process, capture its bytes, detect
that it stopped, kill it on a deadline. What agent output *means* is left to
whoever reads it.

`Harness.AgentAdapter.invoke/2` does the generic Port spawn shared by every
adapter; `Harness.AgentAdapter.Driver.run/3` drives a spawned run to
completion under total/idle/progress deadlines. Termination is derived from
the port closing or a deadline firing — **never** from the process exit
code, which every adapter here treats as advisory-only.

## Installation

Not published to hex.pm. Add it as a `git:` dependency:

```elixir
def deps do
  [
    {:harness_agent_adapter, git: "https://github.com/ZenHive/harness_agent_adapter.git", tag: "v0.1.0"}
  ]
end
```

Pin a `tag:`, `branch:`, or `ref:` per your usual git-dependency practice.

## Usage

```elixir
alias Harness.AgentAdapter
alias Harness.AgentAdapter.Driver
alias Harness.AgentAdapter.Invocation

invocation = %Invocation{
  prompt: "Fix the failing test in lib/foo.ex",
  cwd: "/path/to/isolated/worktree",
  log_tag: "run-123",
  model: "gpt-5.6-sol",
  rule_content: "# Operational rules\n\nRun the project's checks before finishing.\n"
}

{:ok, outcome} = Driver.run(AgentAdapter.Codex, invocation)

outcome.kind        # :exited | {:timed_out, :idle | :total} | {:reflex_halted, reason} | {:error, reason}
outcome.output       # the agent's raw transcript, unparsed
outcome.exit_status   # advisory only — never branch success on this
```

`Driver.run/3` is the composed entry point most callers want (spawn +
drive-to-completion under deadlines). `AgentAdapter.invoke/2` is the lower
layer — it just spawns and returns a `Harness.AgentAdapter.Run` handle for a
caller that wants to drive the receive loop itself.

## Adapters

| Adapter | Headless CLI | Raw output format |
|---|---|---|
| `Harness.AgentAdapter.Claude` | `claude -p` | `--output-format stream-json` |
| `Harness.AgentAdapter.Cursor` | `cursor-agent -p` | `--output-format stream-json` |
| `Harness.AgentAdapter.Codex` | `codex exec` | `--json` |
| `Harness.AgentAdapter.Grok` | `grok -p` / `agent` subcommand | `--output-format streaming-json` |
| `Harness.AgentAdapter.Antigravity` | `agy -p` | plain text |
| `Harness.AgentAdapter.Pi` | `pi -p` | `--mode json` |

All six adapters declare `worktree_isolation: true` — their headless mode
edits only the port's `cwd`, never a directory outside it. Model and agent
are orthogonal: `Invocation.model` threads to each adapter's `--model` flag
independently of which adapter (`assignee`) you dispatch to, so e.g. Cursor
is a multi-model front end, not "the Composer agent."

## Configuration

```elixir
config :harness_agent_adapter, :run,
  total_timeout: 1_800_000,
  idle_timeout: 300_000,
  progress_timeout: 300_000,
  terminate_grace_ms: 1_000
```

All keys are optional; see `Harness.AgentAdapter.Driver`'s moduledoc
for the shipped defaults and what each deadline guards (total-run budget,
idle-output window, no-mechanical-progress window). `:terminate_grace_ms`
is the SIGTERM-to-SIGKILL window `OSProcess.kill_tree/1` waits so agent
CLIs can flush their transcript tail. Per-call `opts` passed to
`Driver.run/3` override the application config.

## Public API

The package's public surface is intentionally small — an adapter and its
callers should need nothing beyond these modules:

- `Harness.AgentAdapter` — the behaviour: required callbacks
  `capabilities/0`, `rule_channel/0`, `build_command/1`; `classify_message/2`
  and `terminate/1` default via `use Harness.AgentAdapter` and are
  overridable. Also hosts `invoke/2`, `attach_rules/2`, `supports?/2`,
  `model_supported?/2`, `model_args/1`, `permission_flag/2`,
  `check_permission_mode/2`, and `resume_args/1`.
- `Harness.AgentAdapter.Driver` — `run/3`, the spawn-and-drive-to-completion
  entry point, with `:on_spawn` / `:on_output` hooks.
- `Harness.AgentAdapter.Watchdog` — the deterministic mid-run guard: idle,
  total, and progress-stall deadlines, plus blocked-command detection
  (`git push --force`, `mix deps.clean`, `rm -rf` outside the worktree).
- `Harness.AgentAdapter.Invocation` — the run-request struct: prompt, cwd,
  session, permission mode, model, rule content, adapter opts, env.
- `Harness.AgentAdapter.Capabilities` — the static per-adapter declaration:
  session resume, permission modes, streaming output, worktree isolation,
  cost tier, auth-env scrub list, model families.
- `Harness.AgentAdapter.Outcome` — the completed-run result: raw `output`,
  advisory `exit_status`, and the authoritative `kind`.
- `Harness.AgentAdapter.Run` — the live-run handle (port, OS pid, adapter,
  composed input) returned by `invoke/2`.
- `Harness.AgentAdapter.Registry` — name-to-`{module, render agent}`
  resolution for the six adapters (`resolve/1`, `delegatable?/1`).
- `Harness.AgentAdapter.RuleDelivery` — the delivered-rules struct threaded
  through `Invocation.rules`.
- `Harness.AgentAdapter.Claude` / `.Cursor` / `.Codex` / `.Grok` /
  `.Antigravity` / `.Pi` — the six shipped adapters.
- `Harness.AgentAdapter.Testing.ConformanceCase` — the reusable ExUnit case
  every adapter is checked against. Ships in `lib/` (not `test/support/`) so
  a downstream consumer defining its own adapter can `use` it directly from
  their own test suite.
- `Harness.AgentAdapter.Testing.ProcessFixture` / `.GitFixture` — the
  throwaway OS process and throwaway git repository the conformance suite's
  generated tests call. They ship in `lib/` for the same reason the case does:
  a consumer's build compiles this package's `lib/` and nothing else.

Two seams make the package standalone rather than harness-coupled:

- **Caller-supplied rule content.** The package never renders or filters
  operational rules — it only chooses *how* they reach each agent
  (`c:Harness.AgentAdapter.rule_channel/0`: an ephemeral system-prompt file
  for Claude, ephemeral `AGENTS.md` / `.cursor/rules/` files for Codex and
  Cursor, a prompt preamble for Grok and Antigravity, or no channel at all).
  The caller renders `Invocation.rule_content` however it wants and hands it
  in; `Harness.AgentAdapter.attach_rules/2` and
  `Harness.AgentAdapter.RulesInjection` handle delivery.
- **The watchdog.** `Harness.AgentAdapter.Watchdog` owns every mid-run
  deadline and the blocked-command guard, independent of any particular
  orchestrator's run lifecycle — a caller driving `invoke/2` directly gets
  the same deterministic reflex halts that `Driver.run/3` uses internally.

## Primary Consumer

[`harness`](https://github.com/ZenHive/harness) is the OTP-native
orchestration engine this package was extracted from and the primary
consumer: it dispatches implementer and reviewer agents into isolated git
worktrees through these adapters as part of its implement → review → land
loop.
