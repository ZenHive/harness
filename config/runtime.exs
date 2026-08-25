import Config

alias Harness.Dashboard.Endpoint

database_config =
  case System.get_env("HARNESS_DATABASE_URL") || System.get_env("DATABASE_URL") do
    nil ->
      base = [
        database: System.get_env("HARNESS_DB_NAME") || "harness_#{config_env()}",
        username: System.get_env("HARNESS_DB_USER") || System.get_env("USER") || "postgres",
        hostname: System.get_env("HARNESS_DB_HOST") || "localhost"
      ]

      case System.get_env("HARNESS_DB_PASSWORD") do
        nil -> base
        password -> Keyword.put(base, :password, password)
      end

    url ->
      [url: url]
  end

config :harness, Harness.Repo, database_config

# Per-host log level. The deployed node runs MIX_ENV=dev (see mix.exs), where
# :debug makes Harness.Repo log every query and an idle BEAM a steady journal
# writer. Set HARNESS_LOG_LEVEL=info on a long-lived host to quiet it without
# changing the env default (which test depends on — see config.exs). An invalid
# value fails the boot loudly rather than being silently ignored.
case System.get_env("HARNESS_LOG_LEVEL") do
  nil ->
    :ok

  level when level in ~w(emergency alert critical error warning notice info debug all none) ->
    config :logger, level: String.to_existing_atom(level)

  other ->
    raise "HARNESS_LOG_LEVEL=#{inspect(other)} is not a valid Logger level"
end

# Operators can relocate the worktree root without recompiling.
if base = System.get_env("HARNESS_WORKTREE_ROOT") do
  config :harness, :worktree, base_dir: Path.expand(base)
end

# Dashboard runtime overrides (Task 50). HARNESS_DASHBOARD_PORT relocates the
# standalone Endpoint; HARNESS_SECRET_KEY_BASE replaces the dev default for any
# non-127.0.0.1 binding.
if port = System.get_env("HARNESS_DASHBOARD_PORT") do
  port = String.to_integer(port)
  config :harness, Endpoint, http: [ip: {127, 0, 0, 1}, port: port]
  config :harness, :dashboard, port: port
end

if secret = System.get_env("HARNESS_SECRET_KEY_BASE") do
  config :harness, Endpoint, secret_key_base: secret
end

# ResultStore backend: default to the Postgres implementation when
# :repo_enabled (the normal case for the harness self-host and any deployment
# with Oban), keep an in-memory ephemeral backend for library consumers that
# mount harness with `repo_enabled: false`. An explicit
# `config :harness, :result_store, ...`
# (or Application.put_env at runtime) always wins.
result_store = Application.get_env(:harness, :result_store)

# Per-run memory watchdog (Task 200) is overridable on this same :run key:
#   config :harness, :run, mem_threshold_kb: 6 * 1024 * 1024, mem_sample_interval: 5_000
# Defaults live in Harness.Run; set these to tune the spawned-tree RSS ceiling
# (KiB) or sample cadence (ms).
#
# Node-pressure admission gate (Task 202) — the aggregate companion to the
# per-run cap — is also on this key:
#   config :harness, :run, mem_highwater_kb: 40 * 1024 * 1024, mem_pressure_snooze: 30
# When host resident memory is over mem_highwater_kb (KiB), Harness.Run.Worker
# snoozes NEW run admission mem_pressure_snooze seconds instead of spawning
# another concurrent tree. Unset, mem_highwater_kb defaults to 85% of detected
# host RAM (or fails open if host RAM can't be probed); an explicit value ≤ 0
# disables the gate. mem_pressure_snooze defaults to 30. Defaults live in
# Harness.Run.Worker.
config :harness, :run, max_hold_timeout: 1_800_000

# Per-host run memory ceiling. This preserves the old local 18 GB tuning without
# hiding it in a boot-read project config file: set
# HARNESS_RUN_MEM_THRESHOLD_GB=18 to cap each spawned agent tree at 18 GiB RSS.
if threshold_gb = System.get_env("HARNESS_RUN_MEM_THRESHOLD_GB") do
  config :harness, :run, mem_threshold_kb: String.to_integer(threshold_gb) * 1024 * 1024
end

if is_nil(result_store) do
  repo_enabled = Application.get_env(:harness, :repo_enabled, true)

  if repo_enabled do
    config :harness, :result_store, {Harness.ResultStore.Postgres, []}
  else
    config :harness, :result_store, {Harness.ResultStore.Memory, []}
  end
end
