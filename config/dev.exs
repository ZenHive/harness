import Config

# Self-register the harness checkout as the default "harness" project in dev,
# so `Harness.ProjectRegistry.lookup("harness")` succeeds against `iex -S mix`
# without a manual registration step. Test/prod stay un-opinionated.
# Consumed by `Harness.ProjectRegistry.init/1`.
#
# `check_command` is a free-text hint the reviewer AI receives in its prompt —
# the reviewer runs the project's checks itself and judges the result; harness
# never executes it. `mix precommit.full` is harness's own mergeable bar
# (precommit + dialyzer); integration tests need a Postgres test DB
# (`MIX_ENV=test mix ecto.create && mix ecto.migrate`).
config :harness, :projects, [
  [
    name: "harness",
    source: {:local, Path.expand("..", __DIR__)},
    check_command: "mix precommit.full",
    roadmap_path: Path.expand("..", __DIR__),
    # The cron poller dispatches the whole `rmap ready --dispatchable` batch each
    # tick; this caps how many of those runs the `project_harness` queue executes
    # concurrently (the rest sit `available` and start as slots free). Without it
    # the queue defaults to limit 1 and the batch serializes. Kept low (3): a wide
    # batch off one `development` snapshot causes stale-base rebase divergence +
    # a shared-reviewer quota cliff; <=3 keeps the base fresh between lands.
    concurrency_cap: 3
  ]
]

# Per-host project registrations live in `config/dev.local.exs` (gitignored).
# That file is free to call `config :harness, :projects, [...]` with its own
# list — copy the harness entry above if you want to keep it available.
# See `config/dev.local.exs.example` for the template.
if File.exists?(Path.expand("dev.local.exs", __DIR__)) do
  import_config "dev.local.exs"
end
