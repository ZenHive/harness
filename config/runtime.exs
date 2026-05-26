import Config

database_config =
  if url = System.get_env("HARNESS_DATABASE_URL") || System.get_env("DATABASE_URL") do
    [url: url]
  else
    then(
      [
        database: System.get_env("HARNESS_DB_NAME") || "harness_#{config_env()}",
        username: System.get_env("HARNESS_DB_USER") || System.get_env("USER") || "postgres",
        hostname: System.get_env("HARNESS_DB_HOST") || "localhost"
      ],
      fn opts ->
        if password = System.get_env("HARNESS_DB_PASSWORD") do
          Keyword.put(opts, :password, password)
        else
          opts
        end
      end
    )
  end

config :harness, Harness.Repo, database_config

# Operators can relocate the worktree root without recompiling.
if base = System.get_env("HARNESS_WORKTREE_ROOT") do
  config :harness, :worktree, base_dir: Path.expand(base)
end
