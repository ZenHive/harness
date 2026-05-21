defmodule Harness.AgentAdapter.ClaudeConformanceTest do
  @moduledoc false

  # Holds the Claude Code adapter to the shared adapter conformance suite. The
  # whole suite is injected by `use`; Claude-specific assertions (argv
  # composition, permission-mode mapping, the `:resume` sentinel) live in
  # `Harness.AgentAdapter.ClaudeTest`.
  use Harness.AgentAdapter.ConformanceCase, adapter: Harness.AgentAdapter.Claude
end
