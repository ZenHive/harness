import Config

alias Harness.Dashboard.Endpoint
alias Harness.Dashboard.ErrorHTML
alias Harness.Notification.CommandSink

# Elixir ships `Calendar.UTCOnlyTimeZoneDatabase` by default, under which any
# zone name raises. Oban's Cron plugin needs a real database to honour the
# `:timezone` below — without it `Harness.Cron.SuiteHealthPoller`'s
# "0 0 * * *" fires at UTC midnight, which is 08:00 in UTC+8.
config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

config :harness, CommandSink,
  command: Path.expand("~/.claude/scripts/harness-herdr-notify.sh"),
  args: []

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
  # Keep settled jobs for 24h (the Pruner default is 60s, which made post-merge
  # audit + landing outcomes vanish before they could be inspected). Land/audit
  # jobs are low-volume; the retention is for observability, not throughput.
  plugins: [{Oban.Plugins.Pruner, max_age: 60 * 60 * 24}]

# HIGH-tier second-grader pairing — see Harness.AuditReview.default_grader/1.
# Maps an implementer agent to the cross-family agent that grades its fix
# (Codex grades Claude, Claude grades Codex). Override to re-pair or to add
# auto-pairs for implementers the default leaves unpaired; an implementer absent
# from the map still gets {:error, {:no_default_grader, implementer}}. Defaults
# to this same map in code when the key is unset.
config :harness, :audit_review, grader_pairs: %{claude: :codex, codex: :claude}

# Autonomous roadmap polling is opt-in. The Oban.Cron entry that runs
# Harness.Cron.RoadmapPoller is registered unconditionally (Task 109) so the
# runtime master toggle has a scheduled tick to act on. The master switch,
# per-project autonomy, dispatch mode, and active `schedule` are all persisted
# in the Postgres settings store (Harness.Cron.Settings). `subscription_env_scrubs`
# removes metered provider keys from subscription-operated agents; set an agent
# entry to false/%{} when that agent should intentionally use its inherited API
# key.
config :harness, :cron_polling,
  subscription_env_scrubs: %{
    claude: %{"ANTHROPIC_API_KEY" => false},
    codex: %{"OPENAI_API_KEY" => false}
  }

# The zone every human-facing daily schedule is expressed in — the cron plugin
# (`Harness.Oban`) reads it, so "Daily (midnight)" in the dashboard preset
# picker means local midnight rather than UTC midnight. Override per host when
# the operator is not in this zone.
config :harness, :cron_timezone, "Asia/Kuala_Lumpur"

# Phoenix LiveView dashboard (Task 50) — Harness.Dashboard.Endpoint + Live.
# `enabled` toggles the supervised standalone Endpoint; mountable consumers
# leave it `false` and route `live "/harness/*path", Harness.Dashboard.Live`
# from their own Phoenix endpoint. `port` only applies to the standalone
# Endpoint; runtime.exs honours HARNESS_DASHBOARD_PORT when set.
config :harness, :dashboard, enabled: true, port: 4018

# Witness notification sinks — see Harness.Notification. The lander fires a
# %Harness.Notification.Event{} on land / blocked / red-post-merge to every sink
# below; an empty/absent list is a silent no-op. The built-in CommandSink execs
# an operator command with the event in HARNESS_NOTIFY_* env vars (uncomment and
# configure to enable). Custom sinks implement the Harness.Notification.Sink
# behaviour; a discerning (buddhi) sink consumes the event struct and acts
# *through* the train, never by hand-merging a tracked branch.
# The configured command is host-specific (like :cron_timezone above): it fans
# events into the operator's Herdr session. The script silently no-ops outside
# Herdr; a missing script is failure-isolated by CommandSink and logged.
config :harness, :notification_sinks, [CommandSink]

# Project source cache — see Harness.Project.Source.Github.
# `cache_root` is where harness clones GitHub-source projects on first run
# and `git fetch`es before every subsequent run.
config :harness, :project, cache_root: Path.expand("~/_DATA/harness/projects")

# Mechanical retry backoff — see Harness.Run.RetryPolicy. Judgment-free: only
# the arithmetic of "how long before the next mechanical re-attempt" lives here
# (Run.Worker snooze timing). A settled verdict is never re-run by policy code.
#   :max_retries    — retries after the first attempt; default 3.
#   :base_delay_ms  — first backoff delay; default 1_000.
#   :max_delay_ms   — backoff cap; default 60_000.
#   :multiplier     — exponential factor; default 2.0.
config :harness, :retry_policy,
  max_retries: 3,
  base_delay_ms: 1_000,
  max_delay_ms: 60_000,
  multiplier: 2.0

# Run lifecycle — see Harness.Run.
# All keys are optional; defaults live in code.
#   :lifetime_timeout    — whole-job wall budget (worktree + implementer + reviewer) in
#                          ms; defaults to 5_400_000 (90 min).
#   :terminal_linger     — how long a settled run stays observable before it stops, in
#                          ms; defaults to 5_000 (5 s).
#   :max_hold_timeout — operator hold safeguard in ms; settles :hold_expired when
#                       elapsed. Defaults to 1_800_000 (30 min). `:infinity` disables.
#   :pollution_allowlist — path patterns ignored by the main-checkout pollution diff
#                          (see `Harness.Worktree.Isolation.default_pollution_allowlist/0`);
#                          defaults to that list when unset.
# All keys keep their code defaults.

# Result persistence — see Harness.ResultStore and runtime.exs.
# Default is chosen at runtime based on :repo_enabled (Postgres when true for
# the harness self-host; memory when false for library consumers). An explicit
# :result_store config value always wins over the repo_enabled heuristic.
# Postgres run-record transcript blobs are retained for 30 days by default via
# :run_records, :transcript_retention_ms; older rows keep every countable fact
# column, while only agent_output/reviewer_output are nulled.
# (The concrete default lives in config/runtime.exs so the flip is in one place.)

# config :harness, Harness.Notification.CommandSink,
#   command: "/usr/local/bin/notify-train.sh",
#   args: []
#
# config :harness, Harness.Notification.FileSink,
#   path: Path.expand("~/.harness/settled.jsonl")
#
# Register sinks above in :notification_sinks, e.g.:
# config :harness, :notification_sinks, [
#   Harness.Notification.CommandSink,
#   Harness.Notification.FileSink
# ]

# Registered orchestration targets — see Harness.Project and Harness.ProjectRegistry.
# Each entry is a keyword list: name, source ({:local, path}), roadmap_path,
# optional concurrency_cap, and an optional `check_command:` free-text hint the
# reviewer AI receives in its prompt (e.g. "mix check.dispatch") — the reviewer runs
# the project's checks itself; harness never executes the command. Registrations
# are seeded via `priv/repo/seeds.exs` (from the tracked .example) or the
# dashboard `/harness/settings` (writes Postgres when enabled); test/prod stay
# un-opinionated and `config/dev.exs` is now minimal.

# Per-run git worktree lifecycle — see Harness.Worktree.
config :harness, :worktree,
  base_dir: Path.expand("~/_DATA/worktrees/.harness"),
  retain_on_failure: true,
  sweep_on_boot: true,
  reap_on_crash: true

config :harness, ecto_repos: [Harness.Repo]

# Agent process timeouts — see Harness.AgentAdapter.Driver. Keep these under the
# dependency's application key; `config :harness, :run` remains owned by
# Harness.Run's lifecycle and memory guards.
config :harness_agent_adapter, :run,
  total_timeout: 1_800_000,
  idle_timeout: 300_000,
  progress_timeout: 300_000

# Logger's own default is :debug, and `Harness.Repo` logs every query at that
# level. On a long-lived node that turns an idle BEAM into a steady journal
# writer — measured 19 lines in three minutes with nothing dispatched, and far
# more once the cron poller runs. That is a per-HOST decision, not a per-env
# one: the deployed node runs MIX_ENV=dev on purpose (see mix.exs), so quieting
# it lives behind HARNESS_LOG_LEVEL in runtime.exs.
# Test must stay :debug. `ExUnit.CaptureLog.capture_log([level: :debug], fn ...)`
# only filters its own handler; it cannot raise the *primary* level, so an :info
# primary silently drops the `Logger.debug` in ResultStore.Postgres's never-raise
# path and the codec tests assert against an empty log.
config :logger, level: if(config_env() in [:dev, :test], do: :debug, else: :info)

config :phoenix, :json_library, Jason

# Autoupdate would have tzdata's background process fetch new IANA releases
# over HTTP for the lifetime of the node. Harness is a local dev daemon, not a
# long-lived server that must track leap-second releases unattended; the
# release vendored with the dep is enough, and `mix deps.update tzdata` is the
# refresh path.
config :tzdata, :autoupdate, :disabled

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
  config :harness, :result_store, {Harness.ResultStore.Memory, scope: :test_default}

  # Disable the node-pressure admission gate (Task 202) by default so worker
  # tests aren't coupled to the live host's free RAM; the gate's own tests
  # override mem_highwater_kb to a deterministic positive value.
  config :harness, :run, mem_highwater_kb: 0

  # repo_enabled is false in test, so the production settings store would be the
  # ephemeral no-op backend. The suite needs a *persistent* (within-BEAM) store
  # to prove a flip survives a simulated restart without a live DB, so default to
  # the test-only in-memory backend; the ephemeral-path test overrides this to
  # `false`, and the Postgres integration test overrides it to the PG backend.
  config :harness, :settings_store, {Harness.Test.SettingsStoreMemory, scope: :test_default}

  config :harness, :worktree,
    base_dir: Path.join(System.tmp_dir!(), "harness_worktrees_test"),
    sweep_on_boot: false,
    reap_on_crash: false
end
