import Config

# Self-register the harness checkout as the default "harness" project in dev,
# so `Harness.ProjectRegistry.lookup("harness")` succeeds against `iex -S mix`
# without a manual registration step. Test/prod stay un-opinionated.
# Consumed by `Harness.ProjectRegistry.init/1` (project_registry.ex:28-43).
# `preset: {:elixir_precommit, ...}` mirrors harness's own merge bar
# (`mix precommit` — coverage gate 80, integration tests excluded) so a green
# dispatched-run verdict implies a mergeable change, not just a green lighter
# `:elixir` stack (Task 97). Threshold + exclusion track mix.exs's `precommit`
# alias; keep them in sync if that alias changes.
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
    preset: {:elixir_precommit, cover_threshold: 80, exclude: [:integration]},
    roadmap_path: Path.expand("..", __DIR__),
    semantic_gate: :always
  ]
]

# Per-host project registrations live in `config/dev.local.exs` (gitignored).
# That file is free to call `config :harness, :projects, [...]` with its own
# list — copy the harness entry above if you want to keep it available.
# See `config/dev.local.exs.example` for the template.
if File.exists?(Path.expand("dev.local.exs", __DIR__)) do
  import_config "dev.local.exs"
end
