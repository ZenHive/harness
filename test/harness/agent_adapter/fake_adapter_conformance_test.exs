defmodule Harness.AgentAdapter.FakeAdapterConformanceTest do
  @moduledoc false

  # Runs the conformance suite against `Harness.FakeAdapter` — the second
  # subject that proves the suite is genuinely reusable, not Claude-coupled, and
  # gives a fully agent-free pass (FakeAdapter spawns shell builtins, so even
  # the `:integration` live test needs no external coding agent).
  use Harness.AgentAdapter.ConformanceCase, adapter: Harness.FakeAdapter
end
