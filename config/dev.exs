import Config

# Self-register the harness checkout as the default "harness" project in dev,
# so `Harness.ProjectRegistry.lookup("harness")` succeeds against `iex -S mix`
# without a manual registration step. Test/prod stay un-opinionated.
# Consumed by `Harness.ProjectRegistry.init/1` (project_registry.ex:28-43).
config :harness, :projects, [
  [
    name: "harness",
    source: {:local, Path.expand("..", __DIR__)},
    preset: :elixir,
    roadmap_path: Path.expand("..", __DIR__)
  ]
]
