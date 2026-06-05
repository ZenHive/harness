defmodule Harness.AgentAdapter.Outcome do
  @moduledoc """
  The result of driving one agent run to completion.

  Returned inside `{:ok, outcome}` by `Harness.AgentAdapter.Driver.run/3`. The
  `kind` field — never `exit_status` — is the authoritative termination signal:
  harness derives *termination* from the process closing or a timeout firing,
  and *success* from the cross-family reviewer's `.harness/review.json` verdict
  (`Harness.Run.Review`), never from the agent's exit code.
  """

  alias Harness.AgentAdapter.Run

  @typedoc """
  How a run ended: `:exited` (the process closed on its own),
  `{:timed_out, :idle}` (killed after the idle window elapsed with no output),
  `{:timed_out, :total}` (killed at the total-run budget),
  `{:reflex_halted, reason}` (killed by a deterministic mid-run guard), or
  `{:error, reason}` (the port itself failed mid-run).
  """
  @type kind :: :exited | {:timed_out, :idle} | {:timed_out, :total} | {:reflex_halted, term()} | {:error, term()}

  @typedoc """
  A completed run.

    * `run` — the final `Harness.AgentAdapter.Run` handle.
    * `output` — the agent's raw output, captured verbatim and unparsed.
    * `exit_status` — the process exit code, or `nil` when the run was killed at
      a timeout. **Advisory only** — recorded for diagnostics, never a success
      signal and never branched on.
    * `kind` — how the run ended (see `t:kind/0`).
  """
  @type t :: %__MODULE__{
          run: Run.t(),
          output: binary(),
          exit_status: integer() | nil,
          kind: kind()
        }

  @enforce_keys [:run, :output, :exit_status, :kind]
  defstruct [:run, :output, :exit_status, :kind]
end
