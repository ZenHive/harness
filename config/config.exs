import Config

config :harness, Oban,
  repo: Harness.Repo,
  queues: [],
  plugins: [Oban.Plugins.Pruner]

# Project source cache — see Harness.Project.Source.Github.
# `cache_root` is where harness clones GitHub-source projects on first run
# and `git fetch`es before every subsequent run.
config :harness, :project, cache_root: Path.expand("~/_DATA/harness/projects")

# Result persistence — see Harness.ResultStore.
# The default store is file-backed and keeps structured run records plus
# reloadable batch results under this root.
config :harness, :result_store, {Harness.ResultStore.File, root: Path.expand("~/.harness/results")}

# Registered orchestration targets — see Harness.Project and Harness.ProjectRegistry.
# Each entry is a keyword list: name, source ({:local, path}), preset or
# check_stack, roadmap_path, and optional concurrency_cap.
# config :harness, :projects, [
#   name: "harness",
#   source: {:local, Path.expand(".")},
#   preset: :elixir,
#   roadmap_path: Path.expand(".")
# ]

# Per-run git worktree lifecycle — see Harness.Worktree.
config :harness, :worktree,
  base_dir: Path.expand("~/_DATA/worktrees/.harness"),
  retain_on_failure: true,
  sweep_on_boot: true

config :harness, ecto_repos: [Harness.Repo]

# Verification check stack — see Harness.Verification.
# Both keys are optional; defaults live in code (elixir_preset/0, 600_000 ms).
#   :checks  — list of %Harness.Verification.Check{}; defaults to elixir_preset/0.
#   :timeout — per-check timeout in ms; defaults to 600_000 (10 min).
# config :harness, :verification,
#   checks: [...],
#   timeout: 600_000

# Run lifecycle & agent timeouts — see Harness.AgentAdapter.Driver and Harness.Run.
# All keys are optional; defaults live in code.
#   :total_timeout       — agent total-run budget in ms; defaults to 1_800_000 (30 min).
#   :idle_timeout        — kill the agent after this many ms with no output; defaults
#                          to 300_000 (5 min).
#   :lifetime_timeout    — whole-job wall budget (worktree + agent + verification) in
#                          ms; defaults to 5_400_000 (90 min).
#   :terminal_linger     — how long a settled run stays observable before it stops, in
#                          ms; defaults to 5_000 (5 s).
#   :max_repair_attempts — how many times a red verdict is fed back to the agent (via
#                          session resume) before the run settles :failed; defaults
#                          to 2. 0 disables the autonomous repair loop.
# config :harness, :run,
#   total_timeout: 1_800_000,
#   idle_timeout: 300_000,
#   lifetime_timeout: 5_400_000,
#   terminal_linger: 5_000,
#   max_repair_attempts: 2

# Retry policy — see Harness.Run.RetryPolicy and Harness.Run.FailureClass.
#   :max_retries    — retries after the first attempt; default 3.
#   :base_delay_ms  — first backoff delay; default 1_000.
#   :max_delay_ms   — backoff cap; default 60_000.
#   :multiplier     — exponential factor; default 2.0.
#   :quota_patterns — regexes for quota/rate-limit detection in agent output.
# config :harness, :retry_policy,
#   max_retries: 3,
#   base_delay_ms: 1_000,
#   max_delay_ms: 60_000,
#   multiplier: 2.0

# Tests create their own isolated per-test worktree roots and pass them
# explicitly, so the configured base_dir is only a fallback. A boot-time sweep
# would race the async suite, and the default base_dir points at real
# worktrees — disable it and redirect the fallback to a tmp path.
if config_env() == :test do
  config :harness, Harness.Repo,
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 10

  config :harness, Oban, testing: :inline
  config :harness, :oban_enabled, false
  config :harness, :repo_enabled, false
  config :harness, :result_store, {Harness.ResultStore.File, root: Path.join(System.tmp_dir!(), "harness_results_test")}

  config :harness, :worktree,
    base_dir: Path.join(System.tmp_dir!(), "harness_worktrees_test"),
    sweep_on_boot: false
end
