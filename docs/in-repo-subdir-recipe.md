# In-repo `harness/` subdirectory recipe

Ship harness **inside** a target repository so contributors clone one repo and
run orchestration from `<repo>/harness/` — no separate harness checkout.

The canonical scaffold lives at `priv/templates/in_repo_harness/` in the harness
library. Copy it verbatim into your project (or wait for the follow-up
`mix harness.init --in-repo` task).

## When to use in-repo vs out-of-repo

| | **In-repo** (`<repo>/harness/`) | **Out-of-repo** (solo harness node) |
|---|---|---|
| **Audience** | Open-source teams; contributors who should not maintain a second checkout | Solo operator orchestrating many projects from one long-running node |
| **Projects** | Single target by convention (this repo) | N registered projects in one BEAM |
| **Roadmap** | Lives in `<repo>/harness/roadmap/` | Each project carries its own `roadmap_path` |
| **Upgrade** | Bump `{:harness, ...}` in `<repo>/harness/mix.exs` | Bump harness once; all projects pick it up |
| **Commit** | Yes — the subdir is part of the target repo | Harness checkout is separate from target repos |

Use **in-repo** when the target project should *include* harness as contributor
machinery (typical for a Rust OSS repo). Use **out-of-repo** when one harness
instance on your laptop drives many registered projects concurrently (Phase 7
solo workflow).

## Directory layout

After copying the template into `my-crate/`:

```
my-crate/                          ← target_root ("..")
├── Cargo.toml
├── src/
└── harness/                       ← Elixir mini-app (this template)
    ├── mix.exs                    ← {:harness, "~> 0.1"} + tidewave + bandit
    ├── mix.lock                   ← generated; commit if your team locks deps
    ├── .gitignore
    ├── config/
    │   ├── config.exs             ← Oban, worktree, result-store defaults
    │   └── runtime.exs            ← Postgres + `target_root` + `:projects`
    ├── lib/
    │   └── project_harness.ex     ← thin wrapper starting `:harness`
    └── roadmap/
        └── tasks.toml             ← rmap roadmap for this repo
```

### `target_root`

`config/runtime.exs` expands `target_root` relative to the `harness/` directory.
The default is `".."` — the parent directory where your Rust (or other) sources
live. Override with `HARNESS_TARGET_ROOT` when the layout differs.

The registered project uses:

- `source: {:local, target_root}` — where worktrees are carved from
- `check_command: "cargo fmt --check && cargo clippy && cargo test"` — free-text hint for the reviewer AI
- `roadmap_path: harness_root` — so rmap reads `harness/roadmap/tasks.toml`

Rename `lib/project_harness.ex` and the `:project_harness` app atom in
`mix.exs` to match your crate (e.g. `my_crate_harness`).

## Gitignore rules

The template `.gitignore` covers the `harness/` subdirectory:

| Path | Ignore? | Why |
|---|---|---|
| `harness/_build/`, `harness/deps/` | Yes | Mix build artifacts |
| `harness/.harness/` | Yes | File-backed result store (configured in `config/config.exs`) |
| `harness/.env` | Yes | Local DB credentials |
| `harness/mix.exs`, `config/`, `lib/`, `roadmap/` | **Commit** | The recipe itself |
| `harness/mix.lock` | Team choice | Commit for reproducible contributor setups |

At the **repo root**, you do not need extra harness entries unless you redirect
worktrees or caches outside `harness/` — those paths default under
`~/_DATA/worktrees/.harness` and `~/_DATA/harness/projects`.

## End-to-end: new Rust project

### 1. Create the Rust crate

```bash
cargo new my-crate
cd my-crate
git init
```

### 2. Copy the harness template

```bash
cp -R /path/to/harness/priv/templates/in_repo_harness ./harness
```

Until `mix harness.init --in-repo` lands, copy from the harness checkout or a
released hex package (`:code.priv_dir(:harness)` at runtime).

While harness is pre-1.0 and not yet on Hex everywhere, point the dep at a path
during local development:

```elixir
# harness/mix.exs
{:harness, path: "../../path/to/harness"},
```

For published releases, use `{:harness, "~> 0.1"}`.

Set the project slug (optional — defaults to `"app"`):

```bash
export HARNESS_PROJECT_NAME=my_crate
```

### 3. PostgreSQL

Harness dispatch persistence (Oban) requires Postgres. Install and start it
locally (Homebrew, apt, Docker — your choice), then create a database.

Using defaults from `config/runtime.exs`:

```bash
createdb harness_my_crate_dev
```

Or pass a URL:

```bash
export HARNESS_DATABASE_URL=postgres://localhost/harness_my_crate_dev
```

### 4. Bootstrap the harness subdir

```bash
cd harness
mix setup          # deps.get + ecto.create + ecto.migrate (Oban jobs table)
```

`Harness.Repo` migrations ship inside the `:harness` dependency — no migration
files to copy into your repo.

### 5. Verify boot

```bash
cd harness
iex -S mix
```

In IEx:

```elixir
Harness.ProjectRegistry.list()
# => [%Harness.Project{name: "my_crate", source: {:local, "/…/my-crate"}, ...}]

Harness.Roadmap.ingest(:next, project: hd(Harness.ProjectRegistry.list()))
```

### 6. Tidewave (optional dev MCP)

From `harness/`:

```bash
mix run --no-halt -e 'Agent.start(fn -> Bandit.start_link(plug: Tidewave, port: 4016) end)'
```

Or add the same alias harness uses in its own `mix.exs`. Tidewave exposes the
running BEAM to agent tooling on port 4016.

### 7. Dispatch a task

With IEx in `harness/`:

```elixir
{:ok, item} = Harness.Roadmap.ingest(:next, project: hd(Harness.ProjectRegistry.list()))
Harness.Run.Supervisor.start_run(item, project, Harness.AgentAdapter.Claude)
```

Worktrees land under `~/_DATA/worktrees/.harness/<project>/<run-id>/` by default.
Override with `HARNESS_WORKTREE_ROOT`.

## Updating harness

1. Edit `harness/mix.exs` — bump `{:harness, "~> 0.1"}` to the new release.
2. Run `mix deps.update harness` inside `harness/`.
3. Run `mix ecto.migrate` if the release notes mention Repo/Oban migration changes.
4. Diff your `config/runtime.exs` against the template in
   `priv/templates/in_repo_harness/config/runtime.exs` — new config keys land there
   first.

Pre-1.0, read `CHANGELOG.md` on every bump; config shapes may shift.

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `HARNESS_PROJECT_NAME` | `"app"` | Registered project slug / Oban queue prefix |
| `HARNESS_TARGET_ROOT` | `".."` | Target repo root, relative to `harness/` |
| `HARNESS_DATABASE_URL` | — | Postgres URL (overrides piecemeal DB vars) |
| `HARNESS_DB_NAME` | `harness_<name>_<env>` | Database name when no URL |
| `HARNESS_DB_USER` | `$USER` / `postgres` | Postgres user |
| `HARNESS_DB_HOST` | `localhost` | Postgres host |
| `HARNESS_DB_PASSWORD` | — | Postgres password when required |
| `HARNESS_WORKTREE_ROOT` | `~/_DATA/worktrees/.harness` | Worktree base directory |

## Related docs

- Solo multi-project workflow: `CLAUDE.md` § Phase 7 multi-project federation
- Dogfooding loop: `docs/dogfooding-workflow.md`
- Template source: `priv/templates/in_repo_harness/`
