defmodule Harness.Verification.Result do
  @moduledoc """
  The captured outcome of running one `Harness.Verification.Check`.

  A check passes iff its process exited `0`. Unlike a coding agent's
  self-reported exit code — which harness never trusts — the check tools
  (`mix test`, `mix dialyzer`, credo, doctor, sobelow) have reliable exit codes
  by design; that is what makes them a trustworthy grader.
  """

  @typedoc """
  One check's result.

    * `name` — the check's label, copied from its `Harness.Verification.Check`.
    * `command` — the executable that ran, kept for readable failure dumps.
    * `status` — `:pass` (process exited `0`), `:fail` (any other exit, a
      timeout, or the executable could not be launched), or `:pre_existing`
      (failed here and on the dispatch base, so it is inherited red).
    * `kind` — *how* the check ended, orthogonal to `status`: `:exited` (ran to
      completion — `status` then carries the pass/fail verdict), `:timed_out`
      (killed at the per-check deadline), or `:not_launched` (the executable
      was not found on `PATH`). Lets a consumer tell a retryable timeout from a
      genuine red check without parsing `output`.
    * `exit_status` — the process exit code, or `nil` when `kind` is not
      `:exited` (the check timed out or never launched).
    * `output` — the combined stdout + stderr captured from the check. On a
      timeout or a launch failure it ends with a `[harness]` explanation line.
  """
  @type t :: %__MODULE__{
          name: String.t(),
          command: String.t(),
          status: :pass | :fail | :pre_existing,
          kind: :exited | :timed_out | :not_launched,
          exit_status: integer() | nil,
          output: String.t()
        }

  @enforce_keys [:name, :command, :status, :kind, :exit_status, :output]
  defstruct [:name, :command, :status, :kind, :exit_status, :output]
end
