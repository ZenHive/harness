import Config

alias Harness.Dashboard.Endpoint

database_config =
  case System.get_env("HARNESS_DATABASE_URL") || System.get_env("DATABASE_URL") do
    nil ->
      host = System.get_env("HARNESS_DB_HOST") || System.get_env("PGHOST")
      password = System.get_env("HARNESS_DB_PASSWORD") || System.get_env("PGPASSWORD")
      port = String.to_integer(System.get_env("PGPORT") || "5432")

      # Local installations can authenticate the OS user over a Unix socket.
      # Explicit connection settings retain precedence over socket discovery.
      socket_dir =
        if is_nil(host) and is_nil(password) do
          Enum.find(["/var/run/postgresql", "/tmp"], fn dir ->
            File.exists?(Path.join(dir, ".s.PGSQL.#{port}"))
          end)
        end

      endpoint =
        cond do
          is_binary(host) and String.starts_with?(host, "/") -> [socket_dir: host]
          is_binary(host) -> [hostname: host]
          socket_dir -> [socket_dir: socket_dir]
          true -> [hostname: "localhost"]
        end

      base = [
        database: System.get_env("HARNESS_DB_NAME") || "harness_#{config_env()}",
        username:
          System.get_env("HARNESS_DB_USER") || System.get_env("PGUSER") ||
            System.get_env("USER") || "postgres",
        port: port
      ]

      case password do
        nil -> base ++ endpoint
        password -> Keyword.put(base ++ endpoint, :password, password)
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
# Node-pressure admission gate (Task 428): Linux MemAvailable measures host
# headroom in KiB. NEW runs snooze at or below mem_lowwater_kb:
#   config :harness, :run, mem_lowwater_kb: 8 * 1024 * 1024, mem_pressure_snooze: 30
# Unset, the reserve defaults to 10% of detected host RAM. Values ≤ 0 disable
# the gate; unavailable samples (including non-Linux) admit. Snooze defaults to
# 30 seconds. HARNESS_NODE_MEM_LOWWATER_GB overrides the reserve at boot in
# integer GiB; set it to 0 to disable admission pressure checks.
# Migration: mem_highwater_kb is removed and ignored. Replace it with
# mem_lowwater_kb or HARNESS_NODE_MEM_LOWWATER_GB, choosing a headroom reserve,
# not the old RSS ceiling. The comparison reverses, and RSS sums have no
# reliable conversion to available memory. Migrate an old disable value to 0.
config :harness, :run, max_hold_timeout: 1_800_000

# Per-host run memory ceiling. This preserves the old local 18 GB tuning without
# hiding it in a boot-read project config file: set
# HARNESS_RUN_MEM_THRESHOLD_GB=18 to cap each spawned agent tree at 18 GiB RSS.
if threshold_gb = System.get_env("HARNESS_RUN_MEM_THRESHOLD_GB") do
  config :harness, :run, mem_threshold_kb: String.to_integer(threshold_gb) * 1024 * 1024
end

if lowwater_gb = System.get_env("HARNESS_NODE_MEM_LOWWATER_GB") do
  config :harness, :run, mem_lowwater_kb: String.to_integer(lowwater_gb) * 1024 * 1024
end

if is_nil(result_store) do
  repo_enabled = Application.get_env(:harness, :repo_enabled, true)

  if repo_enabled do
    config :harness, :result_store, {Harness.ResultStore.Postgres, []}
  else
    config :harness, :result_store, {Harness.ResultStore.Memory, []}
  end
end
