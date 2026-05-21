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
    * `command` — the executable to run, resolved on `PATH` (e.g. `"mix"`).
    * `args` — the argument vector, always a list, never a shell string
      (e.g. `["test.json"]`).
  """
  @type t :: %__MODULE__{
          name: String.t(),
          command: String.t(),
          args: [String.t()]
        }

  @enforce_keys [:name, :command, :args]
  defstruct [:name, :command, :args]
end
