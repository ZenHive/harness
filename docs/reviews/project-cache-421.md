# Task 421 — Cache Preparation: Independent Review Verdict

**Verdict: APPROVE**

Reviewer: cross-family independent evaluator (Cursor/Claude Opus 5, model `claude-opus-5-high`, Herdr agent `cache-review`), read-only on source.
Checkout: `/data/postgresql/harness/cache-preparation` (branch `feat/project-cache-preparation`).
Graded: 2026-09-08, 02:17–02:33 UTC, against the snapshot including the final
`Command.port_env` environment-scrub fix (`command.ex` mtime 02:14:16).

I made **no source edits**. Every finding below was fixed by the implementer before this
grade; nothing in the final snapshot requires repair.

---

## 1. Scope reviewed

| Kind | Files |
|---|---|
| New (cache core) | `lib/harness/project_cache.ex`, `project_cache/{artifacts,command,recipe}.ex` |
| New (helper) | `priv/cache/relocate_plt.exs` |
| New (docs) | `docs/project-cache.md` |
| Modified (integration) | `lib/harness/run/states/dispatched.ex`, `lib/harness/worktree.ex`, `lib/harness/project.ex`, `lib/harness/project_registry/optional_fields.ex` |
| New/modified (tests) | `test/harness/project_cache_test.exs`, `project_cache_plt_test.exs`, `project_cache/command_test.exs`, `run/cache_preparation_test.exs`, `project_registry{,/optional_fields}_test.exs` |

---

## 2. Evidence

All artifacts are on disk and re-readable. No failure was suppressed; no result below is
a self-report.

| Check | Artifact | Result |
|---|---|---|
| `mix precommit.full` | `/tmp/cache-review-check.log` (337 lines, 02:21:25) | exit **1** — stopped at the `test.json --cover` step with `failed: 2`; every step before it green (format, `compile --warnings-as-errors`, `credo --strict`, Doctor 100/100/100, coverage threshold met) |
| Full suite, retry enabled | `/tmp/cache-review-tests.json` (02:26:00) | **2209 passed, 0 failed, 71 excluded, 2 flaky** — exit 0 |
| Isolated flake rerun | `/tmp/cache-review-isolated.json` (02:26:45) | `dashboard/live_mount_test.exs` **24/24** |
| Focused cache suite `--no-retry` | `/tmp/cache-review-focused.json` (02:27:45) | **158 passed, 0 failed**, 7 excluded (165 total), 47.2 s |
| `Command` env-scrub test `--no-retry` | `/tmp/cache-review-command.json` (02:33:04) | **6/6** |
| `mix dialyzer.json` | `/tmp/cache-review-dialyzer.log` (02:27:37) | **0 warnings**, exit 0 |
| `mix sobelow --exit --skip` | `/tmp/cache-review-sobelow.log` (02:28:26) | scan complete, **no findings**, exit 0 |
| `mix ex_dna --max-clones 0` | `/tmp/cache-review-exdna.log` (02:28:44) | **no duplication** (236 files), budget 0/0, exit 0 |
| `mix reach.check --arch --smells` | `/tmp/cache-review-reach.log` (02:29:08) | **Architecture Policy: OK**; 24 advisory smells (pre-existing baseline shape), exit 0 |

### On the `precommit.full` exit 1

The precommit test step runs with `--summary-only`, which by design omits per-failure
detail — the JSON in the log is complete, not truncated. The two failures are named in the
retry-enabled full run as flaky, both in the dashboard LiveView mount suite and both
untouched by this diff:

- `index mount + render empty states report the fleet's condition, not a list's length`
- `index with an in-flight run renders the run row with a kill control, and the kill button cancels it`

They passed 24/24 on one isolated rerun (`/tmp/cache-review-isolated.json`) — one rerun
only, per the AGENTS flaky-test rule. I then ran the remaining `precommit.full` stages
(`ex_dna`, `reach.check`, `dialyzer.json`) separately rather than re-running the suite a
third time; all three are green above. **No cache-related test failed in any run.**

### Coverage of the new surface

From the precommit coverage payload (`threshold_met: true`, project total 84.75% against
an 80% floor):

| Module | Coverage |
|---|---|
| `Harness.ProjectCache` | **100.0%** |
| `Harness.ProjectCache.Recipe` | 96.43% |
| `Harness.ProjectCache.Command` | 90.63% |
| `Harness.ProjectCache.Artifacts` | 87.18% |
| `Harness.ProjectRegistry.OptionalFields` | **100.0%** |
| `Harness.Project` | **100.0%** |
| `Harness.Worktree` | 89.27% |
| `Harness.Run.States.Dispatched` | 85.0% |

### Behavioral evidence emitted by the PLT test

The subsequent focused run independently measured **40,454 ms cold / 1,452 ms warm**,
PLT 2,308,061 bytes, two normal PLT checks and negative-control exit 1
(`/tmp/cache-review-focused.stdout`).

`CACHE_PLT_EVIDENCE` in the precommit log (02:18:22):

```json
{"copied":["_build","priv/plts"],"cold_ms":42654,"warm_ms":1518,"plt_bytes":2308645,
 "dependency_modules":1,"normal_plt_checks":2,"unrelocated_negative_control_status":1}
```

This exercises a real classic PLT with a genuine app `priv` symlink, and the negative
control (unrelocated PLT → nonzero status) proves the relocation is load-bearing rather
than incidentally passing. Treated as **evidence, not a product gate** — no timing
assertion belongs in the suite.

---

## 3. Findings raised during review — all resolved

Two were blocking; the rest were "should fix". Every one is closed in the graded snapshot.

| # | Severity | Finding | Resolution (verified in final source) |
|---|---|---|---|
| 1 | **Blocking** | `publishable/2` rejected `_build/<env>/lib/<app>/priv`, a relative symlink into `<source>/priv`. Any Elixir app with a `priv/` dir could never publish a generation. | `Artifacts.walk_type(:symlink, …)` now accepts a relative link whose *resolved* target is inside the source checkout (`resolve_link/3` follows `..` after traversal, not lexically). Regression-covered by the real-app-`priv` case in `project_cache_plt_test.exs`. |
| 2 | **Blocking** | An exception or exit inside the preparation task propagated out and failed the run (`:worktree_failed`), violating "preparation is never a gate". | `run_preparation/3` now wraps **both** the `Task.Supervisor.async_nolink` spawn and the await in one `try/catch`, yielding `{:error, {:preparation_crashed, reason}}`. Closes the case where a down/saturated `Harness.Run.TaskSupervisor` raised outside the old catch. |
| 3 | Should fix | Cache key hashed the entire node environment, so `_`, `OLDPWD`, `TERM`, terminal-pane vars invalidated it. | `env_inputs` allowlist added to the recipe (`nil` = conservative all). Docs example now includes `PATH`, `MIX_HOME`, `HEX_HOME`, `ERL_LIBS` — the omission of `PATH` would have been a silent-stale-hit source. |
| 4 | Should fix | A deterministically failing `restore_command` re-fails every run with no invalidation path. | Deliberate and now documented: the generation is immutable; the operator corrects the restore command (which changes the key), bumps `version`, or sets `nil`. Accepted as designed. |
| 5 | Should fix | `stop_group/2` ran unconditionally in `try/after`, signalling an already-exited PGID (PID-recycle hazard). | Now fires only on `{:error, :timeout}` / `{:error, :interrupted}`. |
| 6 | Should fix | `Artifacts.restore/7`'s `with` had no `else`; a manifest missing `"source"` or with nonzero `exit_status` fell through. | New `manifest/1` validates and tags `{:error, {:cache_manifest, other}}`; covered by a malformed-manifest test. |
| 7 | Should fix | Start-protocol parsing raised on non-integer PID output. | `started/3` uses `Integer.parse/1`, skips diagnostic lines ahead of the marker, and returns `{:error, {:command_start_protocol, …}}`. |
| 8 | Should fix | Ambient env added after the snapshot leaked into prepared commands, defeating the pinned identity. | `port_env/1` emits explicit `{key, false}` scrubs for every ambient key absent from the snapshot; `command_test.exs` asserts a late-set parent var arrives as `unset`. |
| 9 | Minor | `sobelow_skip` sat on `await_preparation/1`, which performs no file operations, while the functions that do had none. | Annotations moved to `execute/4`, `pack/3`, `seed/5`, `install_one/4`, `copy/2`. Sobelow is green with the skips scoped to real, argument-validated file operations. |
| 10 | Minor | Eviction guidance predated moving the per-run seed outside the builder lock, so `rm -rf` of a stage could race a live seed. | Docs now gate eviction on "after confirming no preparations or per-run copies are running". |

One earlier claim of mine was wrong and I withdraw it: I asserted the recipe was reachable
through the `dispatch-register_project` MCP tool, implying an agent-facing trust boundary.
It is not — that scalar API does not accept `cache_preparation`; the recipe arrives only
via the Elixir `ProjectRegistry` upsert or config, both operator-owned. There is no
agent-writable path to arbitrary command execution here.

---

## 4. Non-blocking notes (no action required to land)

1. **`flock` helper inherits an empty environment.** Resolving `sh` then depends on the
   libc default `PATH`. Fine on this host and every FHS system; on a non-FHS host (Nix
   without a compat layer) it would fail to spawn. Passing an explicit `PATH` to the helper
   would remove the assumption. Not a defect in the current deployment target.
2. **Three advisory `reach --smells` findings land on new files** —
   `artifacts.ex:104` and `command.ex:142` (`++` accumulator in `reduce_while`) and
   `recipe.ex:68` (`paths` traversed twice). Both accumulators iterate recipe-sized lists
   (declared output paths; declared commands), not per-file walks, so the O(n²) shape is
   not reachable at scale. Matches the existing repo baseline; `--smells` is advisory and
   exits 0.
3. **`Artifacts` at 87.18% / `Command` at 90.63%** are above the 80% floor. The uncovered
   lines are I/O error branches (`artifacts.ex` 14, 25, 105-106, 116, 126, 139, 173, 179,
   194). Reasonable; noted only so a future critical-tier reclassification knows where the
   gap is.

---

## 5. What I did not verify

- No live-service, settings, or foreign-worktree interaction, per instruction. I did not
  touch the Tapakly worktree or PID 149098, and killed no process.
- No agent-gate dispatch was executed against a registered project with a live recipe; the
  run-state integration is graded through `test/harness/run/cache_preparation_test.exs`
  (cancellation responsiveness while preparation is in flight) plus reading
  `dispatched.ex`, not through a real end-to-end dispatch.
- The `43 s cold → 1.5 s warm` figure is a single observation on this host, not a
  benchmark.

---

## 6. Verdict rationale

The design holds the harness mantra: preparation **counts** facts (keys, digests, exit
statuses, byte counts) and gates on none of them — a failed, crashed, or timed-out
preparation leaves declared outputs cold, retains legacy warming for other paths, and lets the run proceed. The reviewer AI
remains the only gate. Publication is atomic under `flock` with a validated manifest;
generations are immutable and content-keyed; symlink escape is checked against resolved
targets rather than lexical paths; the environment is pinned and scrubbed on both the
identity and the execution side.

Both blocking defects are fixed and regression-covered. The full mergeable bar is green
apart from two pre-existing dashboard flakes that pass isolated and are untouched by this
diff.

**Approve. Ready to commit.**
