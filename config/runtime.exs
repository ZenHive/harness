import Config

# Operators can relocate the worktree root without recompiling.
if base = System.get_env("HARNESS_WORKTREE_ROOT") do
  config :harness, :worktree, base_dir: Path.expand(base)
end
