defmodule Harness.Verification.Check do
  @moduledoc """
  The specification of one verification check: a name, an executable, and its
  argument vector.

  A list of `Check`s is the verification runner's input — the target project's
  check stack expressed as data. `Harness.Verification.elixir_preset/0` returns
  the default list; callers supply their own via the `:checks` option to
  `Harness.Verification.run/2` or the `:harness, :verification` application
  config.
  """

  @typedoc """
  One check.

    * `name` — a short human label, surfaced in the verdict and logs
      (e.g. `"test"`).
    * `role` — optional semantic category for consumers that need to reason
      across languages (`:format`, `:lint`, `:test`, `:build`, etc.).
    * `command` — the executable to run, resolved on `PATH` (e.g. `"mix"`).
    * `args` — the argument vector, always a list, never a shell string
      (e.g. `["test.json"]`).
    * `env` — per-check environment overrides. String values are set, `false`
      unsets a variable, and `{:harness, :test_database}` resolves to the
      verifier's isolated per-worktree test database name.

  A check is graded purely on its process exit status — there are no
  post-process re-grading hooks. Judgment about *why* a check failed belongs
  to the cross-family reviewer, not to harness code.
  """
  @type env_value :: String.t() | false | {:harness, :test_database}

  @type t :: %__MODULE__{
          name: String.t(),
          role: atom() | nil,
          command: String.t(),
          args: [String.t()],
          env: %{String.t() => env_value()}
        }

  @enforce_keys [:name, :command, :args]
  defstruct [:name, :command, :args, role: nil, env: %{}]
end
