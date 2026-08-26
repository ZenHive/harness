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
  Model family an adapter can execute when `Invocation.model` pins a model.

  The compatibility check is prefix-based in `Harness.AgentAdapter`, not a
  literal model allowlist, because agent CLIs add and rename concrete model IDs.
  Update the family prefix map there when a CLI's `--list-models` output adds a
  new provider family.
  """
  @type model_family :: :anthropic | :openai | :google | :xai | :cursor | :kimi

  @typedoc """
  Model family declaration for adapter-level pin validation.

    * `:any` — the adapter intentionally accepts arbitrary model strings.
    * `[]` — the adapter exposes no command-line model override.
    * `[family]` — model strings must match one of the family's known prefixes.
  """
  @type model_families :: :any | [model_family()]

  @typedoc """
  Capability declaration.

    * `session_resume` — the agent can resume a prior session from a token.
    * `permission_modes` — the autonomy modes the adapter accepts. `:autonomous`
      is the mandatory universal baseline; harness always runs unattended.
    * `streaming_output` — the agent emits output incrementally while it works,
      rather than a single blob at the end.
    * `worktree_isolation` — the agent's headless mode edits only the port
      `cwd` (the run worktree), never the main checkout the worktree was carved
      from. When `false`, dispatch rejects the adapter up front.
    * `cost_tier` — `:free` for adapters whose dispatch consumes no metered
      quota (e.g. pi.dev with a local LLM); `:metered` (the default) for every
      adapter backed by paid quota or a subscription. A caller filters on it to
      surface "free-tier adapters" to the orchestrator; this declaration is the
      cost-awareness primitive — no selection policy lives in the struct itself.
    * `auth_env_scrub` — provider auth env vars to **unset** before spawning the
      CLI so it bills the operator's subscription/login, not a stray API key. A
      Port inherits the BEAM's environment; when e.g. `ANTHROPIC_API_KEY` (Claude)
      or `OPENAI_API_KEY` (Codex) is present, the CLI silently bills the API
      instead of the subscription — and an empty-balance key fails the run
      ("Credit balance is too low"). `Harness.AgentAdapter.invoke/2` scrubs each
      listed key (`{key, false}`). Defaults to `[]` (no scrub).
    * `model_families` — provider families this adapter can run when a roadmap
      task pins `model`. Harness validates this against the resolved adapter
      before spawning; compatibility is family/prefix-based rather than a brittle
      literal allowlist. Defaults to `[]` — the conservative baseline: an adapter
      declares no model support (and so legitimately runs model-less) until it
      opts in by listing families or `:any`. A model-capable adapter (non-`[]`)
      is held to the model-required guard — `invoke/2` rejects a nil model so a
      real agent never falls through to its CLI's ambient default.
  """
  @type t :: %__MODULE__{
          session_resume: boolean(),
          permission_modes: [atom()],
          streaming_output: boolean(),
          worktree_isolation: boolean(),
          cost_tier: cost_tier(),
          auth_env_scrub: [String.t()],
          model_families: model_families()
        }

  defstruct session_resume: false,
            permission_modes: [:autonomous],
            streaming_output: true,
            worktree_isolation: true,
            cost_tier: :metered,
            auth_env_scrub: [],
            model_families: []
end
