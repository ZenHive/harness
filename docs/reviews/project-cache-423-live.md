# Task 423 — operational acceptance review (live Tapakly evidence)

**Scope:** operational acceptance only. Code and the 82-test suite were already
independently reviewed (harness run `run-1788858693817-9d7b2db7`, reviewer
Cursor/Grok 4.6, source shipped in `207b6bc059f2`; see
`docs/reviews/project-cache-423.md`). This review does **not** repeat that.

**Reviewer identity:** Claude Code, model `claude-opus-5` (Opus 5), acting as the
independent operational evaluator. Ran on the already-running harness BEAM
(`localhost:4018`, Elixir 1.20.3 / OTP 29); no second BEAM was started.

**Verdict: APPROVE.**

> Editorial correction by the orchestrator: the probe scripts executed `mix dialyzer --plt`. The reviewer’s original text named `mix dialyzer.json --plt`; the command spelling is corrected below against the actual scripts. Results and verdict are unchanged. “No symlinks” describes the top-level artifact paths, not every nested build entry.


## Precondition — the two SHAs differ only in roadmap files

`git diff --name-only fd58653d 78a68e57` in `/data/postgresql/code/tapakly`:

```
ROADMAP.md
roadmap/data.json
roadmap/tasks.toml
```

3 files changed, 14 insertions(+), 10 deletions(-). Nothing else. `78a68e57`
("roadmap: task 443 -> in_progress") is two roadmap-only commits after
`fd58653d`.

## Baseline — the defect is real and reproduced live

Pre-fix recipe (`/tmp/cache-423-original-recipe.json`, no `exclude_inputs`) on
the same two SHAs produced **two different keys**, i.e. two full 587 MB
generations for a roadmap-only delta:

| worktree | base SHA | key | state |
|---|---|---|---|
| `cache-423-baseline-a` | `fd58653d` | `a3fcd419…30c1` | hit (13 657 ms) |
| `cache-423-baseline-b` | `78a68e57` | `5e75c676…69d4` | hit (14 069 ms) |

Both generations are still on disk at 587 MB each, corroborating the split.

## Candidate recipe — sole delta is `exclude_inputs`

`diff` of `/tmp/cache-423-original-recipe.json` vs
`/tmp/cache-423-candidate-recipe.json` is exactly:

```
> "exclude_inputs": ["ROADMAP.md", "roadmap/data.json", "roadmap/tasks.toml"],
```

Commands, env, `env_inputs`, `identity_commands`, `inputs`, `paths`,
`restore_commands`, `timeout_ms`, `version` are byte-identical.

## Orchestrator acceptance run — identical key across both SHAs

From `/tmp/cache-423-acceptance.json` and `/tmp/cache-423-acceptance.log`:

| label | base SHA | key | state | elapsed |
|---|---|---|---|---|
| cold | `fd58653d` | `85e5f752…f871` | **built** | 738 046 ms (12 min 18 s) |
| warm | `78a68e57` | `85e5f752…f871` | **hit** | 13 058 ms |

Same key across two distinct base SHAs; cold built once, warm hit — a **56×**
preparation speedup. Both worktrees verified on disk at the expected distinct
`HEAD`s (`fd58653d` / `78a68e57`).

Artifact copies are full and isolated, not links into the store:

| worktree | deps | _build | assets/node_modules | PLT |
|---|---|---|---|---|
| cold | 121 M, 156 entries | 424 M | 33 M | 22 335 780 B, inode 3019975461, nlink 1 |
| warm | 121 M, 156 entries | 422 M | 33 M | 22 334 536 B, inode 7248511946, nlink 1 |

The top-level artifact paths are real directories; distinct inodes; link count 1 on both PLTs and on sampled
`deps/phoenix/mix.exs`. The two PLT byte-sizes differ slightly, consistent with
per-worktree path relocation by `restore_commands`.

Normal `mix dialyzer --plt` in the warm worktree: **exit 0**, 28 375 ms;
`/tmp/cache-423-normal-plt.log` ends `PLT is up to date!` — no PLT rebuild, no
`Resolving Hex dependencies`, no dependency compilation. The
`Compiling 699 files (.ex)` line is the Tapakly **application** recompiling
because `_build` was relocated to a new worktree path — expected, and distinct
from dependency/PLT rebuilding.

## My independent live probe

I read `/tmp/cache_423_independent_probe.exs`, then executed it against the
running node:

```
python3 /tmp/cache_fix_mcp.py tidewave '{"name":"project_eval","arguments":{"code":"{result, _} = Code.eval_file(\"/tmp/cache_423_independent_probe.exs\"); result"}}'
```

Launch **exit status 0** at `2026-09-08T09:50:41Z`; the probe ran as a supervised
task (`#PID<0.913325.0>`) and completed by `09:51:27Z`. It created its **own
fresh worktree** `cache-423-independent` (branch `harness/cache-423-independent`,
base `78a68e57`) — not a reuse of the orchestrator's worktrees.

`/tmp/cache-423-independent.json`:

- `state: "hit"`, `key: 85e5f7524c7451ad9eca2fd6767e5b1377d4f8586452787bf25b8ed6c730f871`
  — **identical** to the cold-built key and to the orchestrator's warm key; the
  probe's own in-script assertion `report.key == warm.key` passed.
- `copied: ["deps", "_build", "assets/node_modules"]`, `elapsed_ms: 12 652`.
- `normal_plt: exit_status 0, elapsed_ms 27 903`.

On-disk verification of my probe worktree: `HEAD = 78a68e57`; deps 121 M / 156
entries, `_build` 422 M, `assets/node_modules` 33 M, all real directories (no
symlinks); PLT 22 336 375 B, inode 1342923138, nlink 1 — again a distinct,
isolated copy with its own relocated PLT.

**Rebuild discrimination (mtime windows).** Cache restore ran 09:50:41 →
~09:50:54; `mix dialyzer --plt` ran ~09:50:54 → 09:51:22.

| probe | count |
|---|---|
| dependency `ebin/*.beam` newer than 09:50:56 | **0** (of 7 712 total) |
| files under `deps/` newer than 09:50:56 | **0** |
| Tapakly app beams newer than 09:50:56 | 63 (of 903; the other 840 carry the 09:50:54 copy mtime) |
| PLT mtime | 09:50:52 — written during restore relocation, untouched by the dialyzer run |

`/tmp/cache-423-independent-plt.log` is byte-equivalent in structure to the
acceptance log: `Compiling 699 files (.ex)` → `Finding suitable PLTs` →
`Checking PLT...` → **`PLT is up to date!`**. Greps for `Resolving Hex`,
`New Hex`, `Creating PLT`, `Adding … modules`, `Removing … modules`,
`Looking up modules`, `Compiling deps` return nothing in either log.

**Conclusion on rebuild:** no dependencies were fetched or recompiled and the
PLT was not rebuilt. The only work was Tapakly application recompilation caused
by worktree relocation, which is the expected and permitted cost.

## Mechanism sanity check (not a re-review)

`lib/harness/project_cache.ex:109-131` derives the key from
`git ls-tree -r -z <base_sha>` filtered by `exclude_inputs`, and
`recipe_identity/1` drops an **empty** `exclude_inputs` from the identity tuple —
so pre-existing recipes without exclusions keep their historical keys, while a
non-empty exclusion list intentionally forms a new generation. That matches the
observed key set: the pre-423 generation `bdacee6d…` is untouched and the
candidate opened exactly one new shared generation.

## Limitations (stated honestly)

1. **My probe covered the warm side only.** It hit the generation the
   orchestrator's cold run had already built; it did not itself perform a
   ~12-minute cold build. The cold→warm transition across distinct SHAs rests on
   the orchestrator's `/tmp/cache-423-acceptance.json` plus the `.log` timeline,
   which I inspected directly. My probe independently establishes that a *fresh,
   third* worktree at a roadmap-advanced SHA reaches the same key and requires no
   dependency/PLT rebuild.
2. **My probe used base `78a68e57`, the same SHA as the orchestrator's warm run.**
   The `fd58653d` → same-key direction is evidenced by the orchestrator's cold
   report, not re-run by me.
3. **Recipe not yet active in the registry.** `Harness.ProjectRegistry.lookup("tapakly")`
   still returns `cache_preparation` **without** `exclude_inputs` (I read it,
   changed nothing). Activation remains the orchestrator's step.
4. **Two runs were live** during my probe (`run-1788857218232-3ec8c082`,
   `run-1788857081769-eeef40a6`). I did not touch them, the registry, or any
   existing cache generation; all four store generations remain present
   (`bdacee6d`, `a3fcd419`, `5e75c676`, `85e5f752`). My probe added one worktree
   and branch (`cache-423-independent`), left in place as evidence.
5. Evidence is single-repo (Tapakly) and single-host; it demonstrates the fix on
   the intended production target, not across other registered projects.

## Verdict

Every operational acceptance criterion is met with observed artifacts, not
inference: identical cache key across the two roadmap-only-different SHAs, cold
build then warm hit at 56× speedup, full isolated artifact copies with per-copy
PLT relocation, and a normal `mix dialyzer --plt` that exits 0 reporting
`PLT is up to date!` with zero dependency or PLT rebuilding — reproduced
independently in my own fresh worktree. Application recompilation from worktree
relocation is present and correctly distinguished as expected cost.

**APPROVE** for real Tapakly prewarming and recipe activation.

## Activation — orchestrator, after independent approval

Activated at `2026-09-08T09:55:17.797942Z` against Tapakly HEAD `78a68e5793cee4c677566950884856521768a1b2`. The current tracked build inputs were compared with the accepted warm revision before changing the registration.

Only `cache_preparation` changed: the existing recipe plus `exclude_inputs = ["ROADMAP.md", "roadmap/data.json", "roadmap/tasks.toml"]`. Registry read-back and the directly read PostgreSQL project payload both match the candidate; all other effective project fields match their pre-activation values.

The already-published generation is `85e5f7524c7451ad9eca2fd6767e5b1377d4f8586452787bf25b8ed6c730f871`. The two changed modules were loaded into the existing BEAM from reviewed source; no service restart or active-run cancellation was performed. Code shipped in `207b6bc059f2`; the independent implementation review is recorded in [project-cache-423.md](project-cache-423.md).

Application source and build/configuration changes continue to invalidate this full-build recipe. The measured 13-second hit is preparation time, not total agent execution time; normal application recompilation and review checks still run. Rollback uses the current project registration with `cache_preparation: nil`, restoring legacy warming.

After activation and evidence capture, the orchestrator removed the five task-owned probe worktrees and their merged local branches. Their observed measurements above describe the completed probes; the worktree paths are no longer present. All four cache generations and active agent worktrees were preserved.
