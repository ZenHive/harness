# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Extracted from `harness`.** The `Harness.AgentAdapter` behaviour, its six
  adapters (Claude, Cursor, Codex, Grok, Antigravity, Pi), `Driver`,
  `Watchdog`, `RulesInjection`, `Registry`, `Invocation`, `Capabilities`,
  `Outcome`, `Run`, and `RuleDelivery` moved out of the
  [`harness`](https://github.com/ZenHive/harness) orchestration engine into
  this standalone package, unchanged in behavior. The module namespace stays
  `Harness.AgentAdapter.*`.
- **`Harness.AgentAdapter.Testing.ConformanceCase` ships in `lib/`** as
  public test surface, not tucked under `test/support/` — a downstream
  consumer defining its own adapter can `use` the same conformance suite
  every shipped adapter is checked against. The fixtures its generated tests
  call (`Testing.ProcessFixture`, `Testing.GitFixture`) ship alongside it, so
  the suite resolves in a consumer's build instead of raising
  `UndefinedFunctionError` on a module that never left this repo's
  `test/support/`.
- **Standalone config namespace.** The package reads its own
  `config :harness_agent_adapter, :run` key (`total_timeout:`,
  `idle_timeout:`, `progress_timeout:`, `terminate_grace_ms:`) instead of the
  host application's `config :harness, :run` — no configuration coupling to the
  `harness` repo it was extracted from.
- **Tree-scoped terminate.** `OSProcess.kill/1` and `kill_tree/1` send SIGTERM
  to the adapter pid and every descendant, wait `terminate_grace_ms` (default
  1,000 ms), SIGKILL survivors, and return only once the captured tree is
  quiescent. `c:Harness.AgentAdapter.terminate/1` delegates here, so every
  Driver timeout and host-orchestrator teardown shares one implementation.

### Fixed

- **Cursor rule injection no longer destroys a project-owned file at the same
  path.** `install_cursor_rules/1` wrote `.cursor/rules/harness-operational.mdc`
  unconditionally and `cleanup_injected_rules/1` removed it unconditionally, so
  a target repo that tracks that path lost the file on every run — surfacing as
  a spurious deletion in the delivery diff that downstream reviewers kept
  "restoring". The displaced file is now backed up to
  `.harness/cursor-rules-operational.mdc.orig` at install time and restored at
  cleanup; with no backup the injected file is harness's alone and is still
  removed. Mirrors the existing preserve-the-remainder handling of Codex's
  `AGENTS.md`.

No release has been cut yet.
