defmodule Harness.Roadmap.Item do
  @moduledoc """
  A roadmap task fetched and rendered for dispatch.

  Produced by `Harness.Roadmap.ingest/2` — the input half of a run. An `Item`
  carries the task's identity plus a ready-to-run agent prompt; it is
  deliberately *not* a `Harness.AgentAdapter.Invocation`, because an invocation
  also needs the isolated worktree `cwd`, which the run-lifecycle process
  supplies. Named `Item` rather than `Task` so it never shadows the stdlib
  `Task` module.
  """

  @typedoc """
  An ingested roadmap task.

    * `id` — the rmap task id, a string (e.g. `"6"`).
    * `title` — the task's one-line title, for logging.
    * `prompt` — the task rendered as an agent prompt: the raw, verbatim output
      of `rmap delegate`, passed through untouched.
    * `agent` — the agent the prompt was rendered for. A prompt rendered for one
      agent is not interchangeable with another, so the pairing is carried.
  """
  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          prompt: String.t(),
          agent: :claude | :codex | :cursor
        }

  @enforce_keys [:id, :title, :prompt, :agent]
  defstruct [:id, :title, :prompt, :agent]
end
