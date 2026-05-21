defmodule Harness.AgentAdapter.GrokConformanceTest do
  @moduledoc false

  # Holds the Grok adapter to the shared adapter conformance suite. The whole
  # suite is injected by `use`; Grok-specific assertions (argv composition,
  # permission-mode mapping, the `:resume` sentinel) live in
  # `Harness.AgentAdapter.GrokTest`.
  use Harness.AgentAdapter.ConformanceCase, adapter: Harness.AgentAdapter.Grok
end
