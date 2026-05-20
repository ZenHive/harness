defmodule Harness.AgentAdapter.Invocation do
  @moduledoc """
  A single run request handed to `Harness.AgentAdapter.invoke/2`.

  Carries both *what* the agent should do (`prompt`, `cwd`) and *how* to run it
  (`session`, `permission_mode`, `model`, `adapter_opts`). The two halves are
  always constructed together by the run-lifecycle process, so they share one
  struct rather than a separate spec/options pair.
  """

  @typedoc """
  Run request.

    * `prompt` — the task rendered as a prompt for the agent.
    * `cwd` — absolute path of the isolated working directory (a git worktree).
    * `task_id` — the rmap task id this run serves; used for logging.
    * `session` — an opaque resume token from a prior run, or `nil` for a fresh
      run. Harness round-trips it without interpreting it.
    * `permission_mode` — the autonomy level. `:autonomous` (the default) is the
      universal baseline every adapter must support; any other value must be
      listed in the adapter's `Harness.AgentAdapter.Capabilities`.
    * `model` — an optional model id, passed through to the agent.
    * `adapter_opts` — an escape hatch for per-agent knobs the uniform fields do
      not cover.
  """
  @type t :: %__MODULE__{
          prompt: String.t(),
          cwd: String.t(),
          task_id: String.t(),
          session: term() | nil,
          permission_mode: atom(),
          model: String.t() | nil,
          adapter_opts: keyword()
        }

  @enforce_keys [:prompt, :cwd, :task_id]
  defstruct [
    :prompt,
    :cwd,
    :task_id,
    session: nil,
    permission_mode: :autonomous,
    model: nil,
    adapter_opts: []
  ]
end
