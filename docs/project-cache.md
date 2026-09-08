# Project cache preparation

`Project.cache_preparation` is an opt-in recipe that builds missing caches before
agents start. Existing projects default to `nil` and retain `Worktree.warm/2`.
Registration persists the recipe in the existing project payload; no migration
is required. Upsert the project through `Harness.ProjectRegistry` after deploying
the code. This change does not enable cron, change check hints, or configure any
consuming project automatically.

Preparation is mechanical. Exit zero permits publishing bytes, not approving a
run. The reviewer still runs the project's actual checks and owns the verdict.
The post-merge audit still uses an un-warmed checkout: `Worktree.create/2` and
`checkout_existing/3` do not prepare or warm caches.

## Recipe

String keys allow recipes to travel in JSON or project attrs. Unknown keys and
malformed values are rejected by registration. Example for a Mix project using
Dialyxir with a project PLT configured under `priv/plts`:

```elixir
{:ok, project} = Harness.ProjectRegistry.lookup("my-project")
helper = Application.app_dir(:harness, "priv/cache/relocate_plt.exs")

recipe = %{
  "commands" => [
    "MIX_ENV=dev mix deps.get",
    "MIX_ENV=dev mix deps.compile",
    "MIX_ENV=test mix deps.get",
    "MIX_ENV=test mix deps.compile",
    "MIX_ENV=dev mix dialyzer --plt"
  ],
  "paths" => ["deps", "_build", "priv/plts"],
  "identity_commands" => ["elixir --version", "dialyzer --version"],
  "restore_commands" => ["elixir '#{helper}' priv/plts/*.plt"],
  "env" => %{"MIX_ENV" => "dev"},
  "env_inputs" => [
    "PATH", "MIX_ENV", "MIX_TARGET", "MIX_HOME", "HEX_HOME", "ERL_LIBS",
    "ERL_FLAGS", "ELIXIR_ERL_OPTIONS", "CC", "CFLAGS", "CXXFLAGS", "LDFLAGS"
  ],
  "inputs" => ["."],
  "version" => "1",
  "timeout_ms" => 1_800_000
}

:ok = Harness.ProjectRegistry.upsert(%{project | cache_preparation: recipe})
```

Commands execute sequentially through `sh -c` in a private clone at the run's
frozen base SHA. They are trusted project/operator commands, like build scripts;
this is not a sandbox. Keep them in the foreground and direct outputs into the
checkout. Do not put database writes, service startup, or checks that require
live application state in a recipe. Preparation does not receive run-partition DB
environment variables. It snapshots the harness environment plus `env` overrides.
Changing a preparation recipe grants code execution as the harness user; keep
project registration/upsert restricted to trusted operators. Preparation requires the host's `flock` and `setsid` executables (util-linux on
Linux). An unavailable executable is a reported preparation failure; legacy
warming remains available on other hosts when preparation is disabled. A configured
recipe still withholds its selected paths if required host tools are unavailable.

Every output must be gitignored, exist after commands finish, and contain regular files,
directories or relative symlinks confined to the checkout (including links to
tracked project resources such as the app's `priv` directory). Outputs cannot
contain tracked files, overlap one another, traverse parents, or name git/harness
metadata. Select a specific PLT file if its directory also contains tracked files.
Failures leave selected outputs cold; unkeyed parent copies cannot fill them back
in. Existing agent files, directories and even dangling symlinks are preserved.

## Compatibility and invalidation

The key hashes the repository path, tracked input tree entries at the run's base
SHA, normalized recipe, effective environment, OS/architecture and successful
`identity_commands` output. Environment values and tool output are not written to
the manifest. Tool probes must be deterministic and identify the actual runtime
used by commands; include Node/npm/browser versions for recipes using them.

`env_inputs` selects inherited environment names that participate in the key.
`nil` (the default) hashes all inherited variables conservatively. Declare the
build-relevant names to avoid misses caused by shell/pane variables after a
restart, as in the example. Explicit `env` overrides always participate. The
command environment is snapshotted independently; narrowing the key does not
remove credentials or other inherited settings from the child process.

`inputs` defaults to `["."]`: all tracked content, including build configuration.
This conservatively rebuilds after any source change. A project can explicitly
narrow it to dependency/build inputs, for example `mix.exs`, `mix.lock`, `config`,
`.tool-versions`, local dependency directories, compiler scripts and frontend lock
files. Include every source input that affects the selected artifacts. Missing
inputs are represented by their absence in the tracked tree; committing one
changes the key. Untracked operator configuration must be reflected in `env`,
`version`, or an identity command that prints its digest. Preparation clones
committed source, never uncommitted operator files or an active run's edits.

`exclude_inputs` defaults to `[]`. It removes explicit repository-relative literal
files or directories from the selected tracked inputs. Directory matches stop at
slash boundaries: `roadmap` excludes `roadmap/tasks.toml`, but not `roadmap-old`
or `roadmap.md`. Wildcards have no special meaning. Valid path bytes, including
spaces, tabs and newlines, are preserved. Empty/whitespace entries, absolute
paths, traversal, repository root, NUL and git/harness metadata are rejected.
There is no automatic roadmap exclusion.

Filtering reads NUL-delimited `git ls-tree -r -z` entries, separates metadata at
the first tab, and preserves retained entry bytes and order. Exclusion policy is
part of recipe identity, even for paths absent from the tree. Omitted and empty
exclusions retain exactly the pre-exclusion cache key. This is the existing
registry payload contract with one optional field; no migration is required.

Bump `version` to force a new generation, including after changing an external
restore helper. Different keys never mutate existing generations. A cache hit
means a preparation completed for that key; it makes no claim about product tests.

## Tapakly recipe and operational acceptance

The operator snapshot `/tmp/tapakly-cache-recipe.json` read on 2026-09-08 supplies
the following complete recipe, with only `exclude_inputs` added. Commands,
output paths, toolchain probes, environment and restore helper are unchanged:

```json
{
  "commands": [
    "MIX_ENV=dev mix deps.get",
    "MIX_ENV=dev mix deps.compile",
    "MIX_ENV=test mix deps.get",
    "MIX_ENV=test mix deps.compile",
    "MIX_ENV=dev mix dialyzer --plt",
    "npm ci --prefix assets --no-audit --no-fund"
  ],
  "env": {
    "MIX_ENV": "dev"
  },
  "env_inputs": [
    "PATH",
    "MIX_ENV",
    "MIX_TARGET",
    "MIX_HOME",
    "HEX_HOME",
    "ERL_LIBS",
    "ERL_FLAGS",
    "ELIXIR_ERL_OPTIONS",
    "CC",
    "CFLAGS",
    "CXXFLAGS",
    "LDFLAGS"
  ],
  "identity_commands": [
    "elixir --version",
    "dialyzer --version",
    "node --version",
    "npm --version"
  ],
  "inputs": [
    "."
  ],
  "paths": [
    "deps",
    "_build",
    "assets/node_modules"
  ],
  "restore_commands": [
    "elixir '/data/postgresql/harness/base/_build/dev/lib/harness/priv/cache/relocate_plt.exs' _build/dev/*.plt"
  ],
  "timeout_ms": 1800000,
  "version": "tapakly-1",
  "exclude_inputs": [
    "ROADMAP.md",
    "roadmap/data.json",
    "roadmap/tasks.toml"
  ]
}
```

This full-build recipe keeps `inputs: ["."]`. Application source, configuration
and lockfile changes still invalidate and can block agent start while preparation
runs. Dialyxir's application discovery compiles the application even when the
task receives `--no-compile`; a lockfile-only key would be incorrect.

After implementation and independent review land, the orchestrator owns runtime
module loading, real Tapakly prewarming and registry activation. Before activating,
prepare the recipe against a real committed Tapakly base and record a cold
`:built` result, key and elapsed time. Prepare a second isolated checkout at a
revision differing only in the three excluded files: require `:hit`, the same
key, one published generation and independent copied outputs. Run Tapakly's
normal PLT checks in the consuming checkout with checking enabled and record
exact command results. A preparation success never substitutes for reviewer
approval. The automated real Elixir/PLT fixture also requires normal checks on
both copies and a failing unrelocated-copy negative control.

Record production evidence separately from fixture evidence. This implementation
does not change the running service, registered recipe, active runs or Tapakly
source. Roll back activation by upserting the project with
`cache_preparation: nil`; this restores legacy warming. No generation deletion or
destructive dependency command is needed.

## Publication, interruption and copies

The cache root is `~/.cache/harness/project-cache`, overridable with
`config :harness, :project_cache, root: "/host/cache/harness"` or the
`cache_root:` option on `ProjectCache.prepare/3`. Use a local filesystem supporting
advisory `flock` locks and atomic directory renames. Processes sharing a root share
one lock per key, including separate BEAM instances on the host.

One builder holds `<key>.lock` while creating a uniquely named `.building-*`
directory. Successful commands and complete output copies produce a
`complete.json` manifest; one rename publishes the generation. Other callers wait
for the lock, then reuse it. Per-run copies proceed independently after publication.
Copies use the same Linux reflink/Darwin clone/plain-copy implementation as legacy
warming, never hardlinks or a shared writable build directory.

Restore commands run on staged copies, with `HARNESS_CACHE_SOURCE` identifying
the original builder checkout and `HARNESS_CACHE_TARGET` the final run directory.
Only missing outputs are staged. Restore scripts must tolerate absent outputs
that the agent already owns. Successful restoration precedes installation; a
failed restore discards the staged copies and leaves the immutable generation
unchanged. A restore failure does not delete a generation: a digest mismatch
may be specific to preserved agent state while other fresh runs can still use
it. Correct a failing restore command (which changes the key), or bump `version`
after replacing an external helper; set `cache_preparation: nil` to return to
legacy warming. Malformed manifests report an explicit cache error. Each output is installed by directory/file rename after rechecking the
destination; publication across several output paths is not one filesystem
transaction. This happens before handing the worktree to an agent.

The preparation worker monitors its caller. Cancellation terminates a foreground
command's process group, releases the lock and removes its private stage. A
command failure, timeout, missing output or unsafe path publishes no generation.
A later request retries. Waiters share their own end-to-end deadline; if a
builder exhausts a waiter's budget, that run proceeds cold for the declared
paths instead of starting an agent against an unfinished generation. The deadline covers lock waiting and commands and is
checked before publication/installation; filesystem operations already executing
finish before cleanup. The run state machine stays responsive during preparation. A per-worktree write lock on the owning node serializes preparation with finalization and crash cleanup. Cancellation can acknowledge promptly, but settlement waits for an already-running filesystem copy to finish and its stage to be removed; it cannot remove or retain a worktree while the preparation worker is still writing. A worker whose caller died before acquiring the lock does no preparation.

A hard host/BEAM crash may leave an abandoned `.building-*` directory. No command
can publish it: publication is owned by the BEAM, and retries use a new stage.
After confirming no preparations or per-run copies are running, operators can remove abandoned stages
and obsolete generations to reclaim disk. Do not unlink live `.lock` files:
replacing a lock inode could allow two builders. There is no automatic age-based
cache eviction or assumption that an old stage is safe to delete.

## PLT relocation

Classic PLTs contain absolute BEAM paths. Dialyxir compares those paths with the
current build before adding/removing modules, so a byte copy alone can rebuild
the dependency PLT. The optional `priv/cache/relocate_plt.exs` restore helper
rewrites the producer prefix to the run prefix while preserving the stored types,
contracts, dependencies and BEAM digests. It checks each relocated BEAM digest
against the staged or preserved run bytes. A mismatch fails restoration.

This helper uses OTP's internal classic-PLT load/save functions and the
`plt_info` record contract. It is tested against OTP 29.0.5, not a promise of
compatibility with arbitrary future OTP versions or incremental PLTs. Unsupported
formats fail restoration, leaving normal project checks to rebuild. Keep the
project OTP version in the key and validate the helper during toolchain upgrades.
Normal Dialyzer/Dialyxir PLT checking must remain enabled.

Authority: [OTP classic PLT implementation](https://github.com/erlang/otp/blob/OTP-29.0.5/lib/dialyzer/src/dialyzer_cplt.erl),
[Dialyxir PLT comparison](https://github.com/jeremyjh/dialyxir/blob/master/lib/dialyxir/plt.ex),
and [Dialyzer options](https://www.erlang.org/doc/apps/dialyzer/dialyzer.html).
The executable test builds an actual Elixir dependency in dev/test, creates a PLT,
checks relocated copies normally, and checks that an unrelocated copy fails.

## Frontend and browser caches

Projects can add commands such as `cd assets && npm ci`, add
`assets/node_modules` to `paths`, and include the frontend manifests/lockfiles and
Node/npm versions in the identity. Keep existing `warm_paths`: paths outside a
recipe retain legacy parent-copy behavior. Do not rely on an unrelated parent
`_build` if a recipe owns a child of `_build`; overlapping legacy roots are
withheld to avoid mixing generations.

For Playwright, a project can install browsers into a relative checkout-local
path, for example [`PLAYWRIGHT_BROWSERS_PATH=0`](https://playwright.dev/docs/browsers#hermetic-install)
for a hermetic node_modules install,
and include that path's owning output in `paths`. The project's test configuration
must use the same location. Browser packages do not supply host OS libraries;
operator-installed system prerequisites remain explicit. Other frontend build
binaries can use their own project-selected paths and relocation commands.

## Test databases

`TestDbIsolation` supplies a run-specific partition suffix and performs cleanup;
it has no database-template creation/consumption contract. File caches do not
provision vector/PostGIS. Task 422 tracks consuming an explicitly operator-prepared
test template without cloning application databases or granting broad privileges.
