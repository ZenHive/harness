defmodule Harness.AgentAdapter.RuleDelivery do
  @moduledoc """
  Internal: rule-delivery payload threaded through `Harness.AgentAdapter.attach_rules/2`.

  `argv_flags` are appended to the adapter's headless argv (e.g. Claude's
  `--system-prompt-file`); `prompt` is the preamble-prefixed task prompt used
  by adapters whose `c:Harness.AgentAdapter.rule_channel/0` is
  `:prompt_preamble`. Surfaced via `Harness.AgentAdapter.Invocation.t().rules`.
  """

  @type t :: %__MODULE__{
          argv_flags: [String.t()],
          prompt: String.t() | nil
        }

  defstruct argv_flags: [], prompt: nil
end
