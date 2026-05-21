import Config

# Per-run git worktree lifecycle — see Harness.Worktree.
config :harness, :worktree,
  base_dir: Path.expand("~/_DATA/worktrees/.harness"),
  retain_on_failure: true,
  sweep_on_boot: true

# Verification check stack — see Harness.Verification.
# Both keys are optional; defaults live in code (elixir_preset/0, 600_000 ms).
#   :checks  — list of %Harness.Verification.Check{}; defaults to elixir_preset/0.
#   :timeout — per-check timeout in ms; defaults to 600_000 (10 min).
# config :harness, :verification,
#   checks: [...],
#   timeout: 600_000

# Agent run timeouts — see Harness.AgentAdapter.Driver.
# Both keys are optional; defaults live in code.
#   :total_timeout — total-run budget in ms; defaults to 1_800_000 (30 min).
#   :idle_timeout  — kill after this many ms with no output; defaults to 300_000 (5 min).
# config :harness, :run,
#   total_timeout: 1_800_000,
#   idle_timeout: 300_000

# Tests create their own isolated per-test worktree roots and pass them
# explicitly, so the configured base_dir is only a fallback. A boot-time sweep
# would race the async suite, and the default base_dir points at real
# worktrees — disable it and redirect the fallback to a tmp path.
if config_env() == :test do
  config :harness, :worktree,
    base_dir: Path.join(System.tmp_dir!(), "harness_worktrees_test"),
    sweep_on_boot: false
end
