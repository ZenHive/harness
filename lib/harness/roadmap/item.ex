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

  alias Harness.AgentRegistry
  alias Harness.CapabilityDomain

  @typedoc """
  An ingested roadmap task.

    * `id` — the rmap task id, a string (e.g. `"6"`).
    * `title` — the task's one-line title, for logging.
    * `prompt` — the task rendered as an agent prompt: the raw, verbatim output
      of `rmap delegate`, passed through untouched.
    * `agent` — the agent the prompt was rendered for. A prompt rendered for one
      agent is not interchangeable with another, so the pairing is carried.
    * `body` — the task's original `body` field (intent at scoping time), or
      `nil` when the task carries none. The rendered `prompt` already embeds the
      body, but it's carried structurally so the semantic gate and any triage
      agent can read the task's contract without re-parsing the prompt.
    * `acceptance_criteria` — the task's structured acceptance criteria as a list
      of strings; an empty list when the task declares none.
    * `domains` — advisory capability-domain tags copied onto run records at
      settle time; empty for untagged production tasks and historical ingests.
    * `model` — the task's pinned `model` field from rmap when present (an LLM
      id like `claude-opus-4-7`, or an agent routing token like `codex`); carried
      through dispatch as the requested model when the agent does not self-report.
  """
  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          prompt: String.t(),
          agent: AgentRegistry.agent(),
          body: String.t() | nil,
          acceptance_criteria: [String.t()],
          domains: [CapabilityDomain.t()],
          model: String.t() | nil
        }

  @enforce_keys [:id, :title, :prompt, :agent]
  defstruct [:id, :title, :prompt, :agent, :body, acceptance_criteria: [], domains: [], model: nil]
end
