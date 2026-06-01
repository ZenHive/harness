import Config

# Self-register the harness checkout as the default "harness" project in dev,
# so `Harness.ProjectRegistry.lookup("harness")` succeeds against `iex -S mix`
# without a manual registration step. Test/prod stay un-opinionated.
# Consumed by `Harness.ProjectRegistry.init/1` (project_registry.ex:28-43).
# `preset: {:elixir_precommit, ...}` mirrors harness's merge bar plus the
# DB-backed integration contract suite. The local fast `mix precommit` alias
# still excludes `:integration`; harness dogfooding opts in here because the
# verifier can provision a per-worktree Postgres test DB before grading.
#
# `semantic_gate: :always` opts harness's own dogfooding into the cross-family
# semantic gate (Task 99) even though it lands manually (Task 123). A green
# verdict only means "suite passed", not "acceptance criteria met" — Task 108
# settled green while objectively incomplete. The gate re-checks each green run
# with an opposite-family grader (claude ⇒ codex by default), so a dispatched
# task whose diff stubs the hard case or solves only the adjacent problem is
# rejected back into the repair loop instead of hand-finished on land.
# Requires the opposite-family agent CLI to be installed for headless dispatch;
# set to `:auto_land_only` to revert to gate-iff-auto-land (the default).
config :harness, :projects, [
  [
    name: "harness",
    source: {:local, Path.expand("..", __DIR__)},
    preset: {:elixir_precommit, cover_threshold: 80, include: [:integration], database: :postgres},
    roadmap_path: Path.expand("..", __DIR__),
    semantic_gate: :always,
    # The cron poller dispatches the whole `rmap ready --dispatchable` batch each
    # tick; this caps how many of those runs the `project_harness` queue executes
    # concurrently (the rest sit `available` and start as slots free). Without it
    # the queue defaults to limit 1 and the batch serializes.
    concurrency_cap: 10
  ]
]

# Per-host project registrations live in `config/dev.local.exs` (gitignored).
# That file is free to call `config :harness, :projects, [...]` with its own
# list — copy the harness entry above if you want to keep it available.
# See `config/dev.local.exs.example` for the template.
if File.exists?(Path.expand("dev.local.exs", __DIR__)) do
  import_config "dev.local.exs"
end
