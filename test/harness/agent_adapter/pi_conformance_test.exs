defmodule Harness.AgentAdapter.PiConformanceTest do
  @moduledoc false

  # Holds the pi.dev adapter to the shared adapter conformance suite. The whole
  # suite is injected by `use`; pi-specific assertions (argv composition, the
  # `:resume` sentinel, AGENTS.md rules injection) live in
  # `Harness.AgentAdapter.PiTest`.
  use Harness.AgentAdapter.ConformanceCase, adapter: Harness.AgentAdapter.Pi
end
