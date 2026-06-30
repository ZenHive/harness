import Config

# target_root: ".." — the parent of this `harness/` directory (the target repo root).
harness_root = Path.expand("..", __DIR__)
target_root = Path.expand(System.get_env("HARNESS_TARGET_ROOT") || "..", harness_root)
project_name = System.get_env("HARNESS_PROJECT_NAME") || "app"

database_config =
  if url = System.get_env("HARNESS_DATABASE_URL") || System.get_env("DATABASE_URL") do
    [url: url]
  else
    then(
      [
        database: System.get_env("HARNESS_DB_NAME") || "harness_#{project_name}_#{config_env()}",
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

if base = System.get_env("HARNESS_WORKTREE_ROOT") do
  config :harness, :worktree, base_dir: Path.expand(base)
end

# check_command is a free-text hint handed to the reviewer AI — the reviewer
# runs the target project's checks itself; harness never executes this command.
config :harness, :projects, [
  [
    name: project_name,
    source: {:local, target_root},
    check_command: "cargo fmt --check && cargo clippy -- -D warnings && cargo test",
    languages: [:rust],
    roadmap_path: harness_root,
    concurrency_cap: 1
  ]
]
