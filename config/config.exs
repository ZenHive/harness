import Config

alias Harness.Dashboard.Endpoint
alias Harness.Dashboard.ErrorHTML

config :harness, Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: 4018],
  server: true,
  pubsub_server: Harness.PubSub,
  live_view: [signing_salt: "harness-dashboard-live-view-salt"],
  # Static secret_key_base is acceptable for the local dashboard which only
  # binds 127.0.0.1; runtime.exs replaces it with HARNESS_SECRET_KEY_BASE in
  # prod-like deployments.
  secret_key_base: "harness-dashboard-default-secret-key-base-64-chars-min-or-phoenix-rejects-it",
  render_errors: [
    formats: [html: ErrorHTML],
    layout: false
  ]

config :harness, Oban,
  repo: Harness.Repo,
  queues: [],
  plugins: [Oban.Plugins.Pruner]

# Autonomous roadmap polling is opt-in. When enabled, Harness.Oban appends an
# Oban.Plugins.Cron entry that runs Harness.Cron.RoadmapPoller on this schedule.
config :harness, :cron_polling,
  enabled: false,
  schedule: "0 */2 * * *"

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
#   :pollution_allowlist — path patterns ignored by the main-checkout pollution diff
#                          (see `Harness.Worktree.Isolation.default_pollution_allowlist/0`);
#                          defaults to that list when unset.
# config :harness, :run,
#   total_timeout: 1_800_000,
#   idle_timeout: 300_000,
#   lifetime_timeout: 5_400_000,
#   terminal_linger: 5_000,
#   max_repair_attempts: 2

# Cross-agent repair is opt-in. When enabled, a repeated verification failure
# can spend one repair move on a one-shot opposite-agent grade before the next
# same-agent repair pass. Supported keys:
#   :enabled — bool, default false.
#   :grader — adapter module override; required when the implementer is not
#             `:claude` or `:codex` (AuditReview only auto-pairs those two).
#             Run falls back to normal same-agent repair when missing.
#   :model / :adapter_opts / :total_timeout / :idle_timeout — pass-throughs
#             forwarded to `Harness.AuditReview.grade_fix/1`.
config :harness, :cross_agent_repair, enabled: false

# Phoenix LiveView dashboard (Task 50) — Harness.Dashboard.Endpoint + Live.
# `enabled` toggles the supervised standalone Endpoint; mountable consumers
# leave it `false` and route `live "/harness/*path", Harness.Dashboard.Live`
# from their own Phoenix endpoint. `port` only applies to the standalone
# Endpoint; runtime.exs honours HARNESS_DASHBOARD_PORT when set.
config :harness, :dashboard, enabled: true, port: 4018

# Project source cache — see Harness.Project.Source.Github.
# `cache_root` is where harness clones GitHub-source projects on first run
# and `git fetch`es before every subsequent run.
config :harness, :project, cache_root: Path.expand("~/_DATA/harness/projects")

# Result persistence — see Harness.ResultStore.
# The default store is file-backed and keeps structured run records plus
# reloadable batch results under this root.
config :harness, :result_store, {Harness.ResultStore.File, root: Path.expand("~/.harness/results")}

# Registered orchestration targets — see Harness.Project and Harness.ProjectRegistry.
# Each entry is a keyword list: name, source ({:local, path}), roadmap_path,
# optional concurrency_cap, and a check-stack declaration — either a singular
# `preset:`/`check_stack:` (one stack at the repo root) or `stacks:` (a list of
# `[preset:/check_stack:, workdir:]` for multi-language monorepos, each run in
# its own subdirectory). Dev self-registers the harness checkout via
# config/dev.exs; test/prod stay un-opinionated.

# Per-run git worktree lifecycle — see Harness.Worktree.
config :harness, :worktree,
  base_dir: Path.expand("~/_DATA/worktrees/.harness"),
  retain_on_failure: true,
  sweep_on_boot: true

config :harness, ecto_repos: [Harness.Repo]

config :phoenix, :json_library, Jason

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

if config_env() == :dev do
  import_config "dev.exs"
end

# Tests create their own isolated per-test worktree roots and pass them
# explicitly, so the configured base_dir is only a fallback. A boot-time sweep
# would race the async suite, and the default base_dir points at real
# worktrees — disable it and redirect the fallback to a tmp path.
if config_env() == :test do
  config :harness, Endpoint,
    adapter: Bandit.PhoenixAdapter,
    http: [ip: {127, 0, 0, 1}, port: 4099],
    server: false,
    pubsub_server: Harness.PubSub,
    live_view: [signing_salt: "harness-dashboard-test-salt"],
    secret_key_base: "harness-dashboard-test-secret-key-base-64-chars-min-or-phoenix-rejects-it",
    render_errors: [formats: [html: ErrorHTML], layout: false]

  # The standalone Endpoint isn't supervised in test (dashboard enabled: false);
  # test/test_helper.exs starts it directly for Phoenix.LiveViewTest. server:
  # false means it never binds :4018 (the dev BEAM holds it) — LiveViewTest
  # drives the in-process LiveView client, no real socket server needed.
  config :harness, Endpoint, server: false

  config :harness, Harness.Repo,
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 10

  config :harness, Oban, testing: :inline
  config :harness, :dashboard, enabled: false, port: 4018
  config :harness, :oban_enabled, false
  config :harness, :repo_enabled, false
  config :harness, :result_store, {Harness.ResultStore.File, root: Path.join(System.tmp_dir!(), "harness_results_test")}

  config :harness, :worktree,
    base_dir: Path.join(System.tmp_dir!(), "harness_worktrees_test"),
    sweep_on_boot: false
end
