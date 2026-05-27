import Config

harness_root = Path.expand("..", __DIR__)

config :harness, Oban,
  repo: Harness.Repo,
  queues: [],
  plugins: [Oban.Plugins.Pruner]

config :harness, :project, cache_root: Path.expand("~/_DATA/harness/projects")

config :harness, :worktree,
  base_dir: Path.expand("~/_DATA/worktrees/.harness"),
  retain_on_failure: true,
  sweep_on_boot: true

config :harness, :result_store,
  {Harness.ResultStore.File, root: Path.join(harness_root, ".harness/results")}

config :harness, ecto_repos: [Harness.Repo]

if config_env() == :test do
  config :harness, :repo_enabled, false
  config :harness, :oban_enabled, false
  config :harness, :worktree, sweep_on_boot: false
end
