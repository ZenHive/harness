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
  Capability declaration.

    * `session_resume` — the agent can resume a prior session from a token.
    * `permission_modes` — the autonomy modes the adapter accepts. `:autonomous`
      is the mandatory universal baseline; harness always runs unattended.
    * `streaming_output` — the agent emits output incrementally while it works,
      rather than a single blob at the end.
  """
  @type t :: %__MODULE__{
          session_resume: boolean(),
          permission_modes: [atom()],
          streaming_output: boolean()
        }

  defstruct session_resume: false,
            permission_modes: [:autonomous],
            streaming_output: true
end
