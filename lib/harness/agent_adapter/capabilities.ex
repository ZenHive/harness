defmodule Harness.AgentAdapter.Capabilities do
  @moduledoc """
  Static capability declaration for a `Harness.AgentAdapter` implementation.

  Every adapter returns one of these from its
  `c:Harness.AgentAdapter.capabilities/0` callback. Fields carry the
  conservative baseline as defaults, so an adapter declares only what differs:

      %Harness.AgentAdapter.Capabilities{session_resume: true}

  Capabilities describe what the agent's headless mode can do — they are not
  per-run state.
  """

  @typedoc """
  Cost tier of the adapter's headless mode.

    * `:free` — runs against a free/self-hosted backend at no per-call cost
      (e.g. pi.dev driving a local LLM). Surfaces the "no metered call" signal
      to dispatch without yet baking in any selection policy.
    * `:metered` — every dispatch consumes paid quota or subscription budget
      (Claude/Cursor/Codex/Grok/Antigravity). The conservative default — an
      adapter that does not opt in stays `:metered` and the existing dispatch
      semantics are preserved.
  """
  @type cost_tier :: :free | :metered

  @typedoc """
  Capability declaration.

    * `session_resume` — the agent can resume a prior session from a token.
    * `permission_modes` — the autonomy modes the adapter accepts. `:autonomous`
      is the mandatory universal baseline; harness always runs unattended.
    * `streaming_output` — the agent emits output incrementally while it works,
      rather than a single blob at the end.
    * `worktree_isolation` — the agent's headless mode edits only the port
      `cwd` (the run worktree), never the main checkout the worktree was carved
      from. When `false`, `Harness.Run` rejects dispatch up front.
    * `cost_tier` — `:free` for adapters whose dispatch consumes no metered
      quota (e.g. pi.dev with a local LLM); `:metered` (the default) for every
      adapter backed by paid quota or a subscription. Used by
      `Harness.AgentRegistry` to surface "free-tier adapters" to the
      orchestrator; this declaration is the cost-awareness primitive — no
      selection policy lives in the struct itself.
  """
  @type t :: %__MODULE__{
          session_resume: boolean(),
          permission_modes: [atom()],
          streaming_output: boolean(),
          worktree_isolation: boolean(),
          cost_tier: cost_tier()
        }

  defstruct session_resume: false,
            permission_modes: [:autonomous],
            streaming_output: true,
            worktree_isolation: true,
            cost_tier: :metered
end
