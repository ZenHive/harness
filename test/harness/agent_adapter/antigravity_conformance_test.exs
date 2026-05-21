defmodule Harness.AgentAdapter.AntigravityConformanceTest do
  @moduledoc false

  # Holds the Antigravity adapter to the shared adapter conformance suite. The
  # whole suite is injected by `use`; Antigravity-specific assertions (argv
  # composition, permission-mode mapping, etc.) live in
  # `Harness.AgentAdapter.AntigravityTest`.
  use Harness.AgentAdapter.ConformanceCase, adapter: Harness.AgentAdapter.Antigravity
end
