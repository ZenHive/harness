defmodule Harness.AgentAdapter.CursorConformanceTest do
  @moduledoc false

  # Holds the Cursor adapter to the shared adapter conformance suite — the gate
  # every adapter passes unchanged. The whole suite is injected by `use`;
  # Cursor-specific assertions (argv composition, the `--force --trust`
  # autonomous mapping, the `:resume` sentinel) live in
  # `Harness.AgentAdapter.CursorTest`.
  use Harness.AgentAdapter.ConformanceCase, adapter: Harness.AgentAdapter.Cursor
end
