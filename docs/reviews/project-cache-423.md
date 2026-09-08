# Task 423 — cache exclusion review evidence

## Evaluator status

**Verdict: APPROVE** (harness run `run-1788858693817-9d7b2db7`, review attempt 1).

Independent reviewer: Cursor/Grok 4.6, cross-family gate on the implementer
delivery at `8433651`. Production Tapakly prewarm/registry activation was not
performed in this worktree (orchestrator-owned after land).

Reviewer fix committed in this worktree: the RunCase regression now also asserts
the two retained worktrees are at distinct `HEAD` SHAs, so a stale-base create
cannot silently share one build.

## Independent reviewer checks — 2026-09-08

Focused suite (including `:integration`):

```sh
mix test.json test/harness/project_cache_test.exs test/harness/project_cache_plt_test.exs test/harness/run/cache_preparation_test.exs test/harness/project_registry_test.exs --include integration --no-retry --quiet --cover --output /tmp/review-423-focused-1788858693817.json
```

Exit 0: 82 passed, 0 failed/invalid/excluded/skipped; 52.512 seconds.
`Harness.ProjectCache`: 100% (70/70); `Harness.ProjectCache.Recipe`: 100% (31/31).

Real Elixir/PLT fixture evidence from that execution:

```json
{"copied":["_build","priv/plts"],"cold_ms":44904,"warm_ms":1676,"plt_bytes":2308425,"dependency_modules":1,"normal_plt_checks":2,"unrelocated_negative_control_status":1}
```

After pinning distinct lifecycle SHAs:

```sh
mix test.json test/harness/run/cache_preparation_test.exs --include integration --no-retry --quiet --output /tmp/review-423-lifecycle.json
```

Exit 0: 2 passed, 0 failed.

Dispatch gate:

```sh
mix check.dispatch > /tmp/harness-check-dispatch-review-423.log 2>&1
mix check.dispatch > /tmp/harness-check-dispatch-review-423-final.log 2>&1
```

Both exit 0. Format, `compile --warnings-as-errors`, Credo strict (no issues),
Doctor 242/242 modules at 100% doc/spec coverage, Sobelow scan complete with no
findings. `git diff --check` clean on the delivery plus reviewer edit.

The logged `FunctionClauseError` in `Path.expand/1` is the existing
`cache_root: nil` crash-path test, not a new defect.

Tapakly recipe documented in `docs/project-cache.md` matches
`/tmp/tapakly-cache-recipe.json` with only `exclude_inputs` added
(`ROADMAP.md`, `roadmap/data.json`, `roadmap/tasks.toml`). Generic recipe
defaults were not replaced with Tapakly.

## Implementer checks — 2026-09-08

Before production-module edits:

```sh
mix test.json --cover --quiet --output /tmp/task423-baseline-1788858693.json
```

Exit 0: 2,213 passed, 0 failed, 71 excluded, 2 reported flaky (2,286 total).
`Harness.ProjectCache`: 100%; `Harness.ProjectCache.Recipe`: 96.43%. Both meet
the required pre-edit tiers, including the 95% parser tier.

Focused suite:

```sh
mix test.json test/harness/project_cache_test.exs test/harness/project_cache_plt_test.exs test/harness/run/cache_preparation_test.exs test/harness/project_registry_test.exs --include integration --no-retry --quiet --output /tmp/task423-focused-final-1788858693.json
```

Exit 0: 82 passed, 0 failed/excluded/skipped; 49.656 seconds. This includes the
real Postgres payload round trip and two real run-state-machine executions using
the existing fake agent adapter. Both roadmap revisions share one build and
isolated copies; the reviewer rejection still fails each run.

Real Elixir/PLT fixture evidence from that execution:

```json
{"copied":["_build","priv/plts"],"cold_ms":42224,"warm_ms":1675,"plt_bytes":2308529,"dependency_modules":1,"normal_plt_checks":2,"unrelocated_negative_control_status":1}
```

The cold and warm worktrees have different base SHAs separated by a roadmap-only
commit, with identical cache keys. Both normal PLT checks pass. The original
unrelocated PLT fails with the expected missing producer BEAM paths. These are
fixture results, not production Tapakly acceptance evidence.

After strengthening the lifecycle rejection assertion and fixing a test alias:

```sh
mix test.json test/harness/run/cache_preparation_test.exs test/harness/project_registry_test.exs --include integration --no-retry --quiet --output /tmp/task423-handoff-1788858693.json
```

Exit 0: 61 passed, 0 failed/excluded/skipped.

After adding explicit `.harness-active` exclusion rejection:

```sh
mix test.json test/harness/project_cache_test.exs --no-retry --cover --quiet --output /tmp/task423-cache-final-1788858693.json
mix check.dispatch > /tmp/task423-dispatch-handoff-1788858693.log 2>&1
```

Both exit 0. Cache tests: 20 passed, 0 failed/excluded/skipped;
`Harness.ProjectCache`: 98.57%, `Harness.ProjectCache.Recipe`: 100%.
Dispatch checks: format, warnings-as-errors compilation, strict Credo, Doctor
and Sobelow passed. `git diff --check` passed.

An earlier focused run failed one new assertion that expected struct registration
to materialize recipe defaults; registration preserves the supplied struct and
preparation normalizes it. The assertion now checks the actual normalization
contract. An earlier dispatch check flagged a missing test alias; it was fixed.
No check was disabled or weakened.

## Acceptance coverage and operational handoff

- Excluded additions, edits and removals preserve the key; application source,
  configuration and lock changes rebuild. Directory siblings and literal
  wildcard/tab/newline/space filenames are exercised.
- Independent reconstruction of the old key tuple checks omitted/empty
  compatibility and retained raw tree bytes with nonempty exclusion policies.
- Validation rejects unsafe paths and invalid types; exclusions survive the
  existing registry persistence/reload path without a migration.
- The live run lifecycle and real Elixir/PLT regressions retain review gating,
  isolated artifacts, normal PLT checking and the unrelocated negative control.

`docs/project-cache.md` contains the complete operator Tapakly recipe read from
`/tmp/tapakly-cache-recipe.json`, adding only the three approved exclusions, plus
cold/hit/normal-PLT operational acceptance and rollback with
`cache_preparation: nil`. The orchestrator owns production prewarming, activation
and runtime loading after review and landing; none occurred in this worktree.
