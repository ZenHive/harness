defmodule Harness.AgentAdapter.Invocation do
  @moduledoc """
  A single run request handed to `Harness.AgentAdapter.invoke/2`.

  Carries both *what* the agent should do (`prompt`, `cwd`) and *how* to run it
  (`session`, `permission_mode`, `model`, `adapter_opts`, `env`). The two halves
  are always constructed together by the run-lifecycle process, so they share
  one struct rather than a separate spec/options pair.
  """

  @typedoc """
  Run request.

    * `prompt` — the task rendered as a prompt for the agent.
    * `cwd` — absolute path of the isolated working directory (a git worktree).
    * `task_id` — the rmap task id this run serves; used for logging.
    * `session` — an opaque resume signal, or `nil` for a fresh run. Harness
      round-trips it without interpreting it; each adapter decides what a
      non-`nil` value means. An adapter that resumes the most recent
      conversation in `cwd` (the Claude Code adapter) takes the `:resume`
      sentinel rather than a literal token.
    * `permission_mode` — the autonomy level. `:autonomous` (the default) is the
      universal baseline every adapter must support; any other value must be
      listed in the adapter's `Harness.AgentAdapter.Capabilities`.
    * `model` — an optional model id, passed through to the agent.
    * `language` — optional target language signal from the project's check
      stack, used only to select language-specific injected rule sections.
    * `adapter_opts` — an escape hatch for per-agent knobs the uniform fields do
      not cover.
    * `env` — caller-controlled environment for the spawned agent. Map of
      variable name to either a string value (set/override) or `false` (unset/scrub
      so the agent does not inherit it from the orchestrator). The adapter's
      `build_command/1` threads these into the env list returned to the port
      spawn. Defaults to `%{}`.
  """
  @type t :: %__MODULE__{
          prompt: String.t(),
          cwd: String.t(),
          task_id: String.t(),
          session: term() | nil,
          permission_mode: atom(),
          model: String.t() | nil,
          language: atom() | nil,
          adapter_opts: keyword(),
          env: %{optional(String.t()) => String.t() | false},
          rules: Harness.AgentAdapter.RuleDelivery.t() | nil
        }

  @enforce_keys [:prompt, :cwd, :task_id]
  defstruct [
    :prompt,
    :cwd,
    :task_id,
    session: nil,
    permission_mode: :autonomous,
    model: nil,
    language: nil,
    adapter_opts: [],
    env: %{},
    rules: nil
  ]
end
