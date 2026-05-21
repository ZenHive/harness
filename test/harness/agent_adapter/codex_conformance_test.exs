defmodule Harness.AgentAdapter.CodexConformanceTest do
  @moduledoc false

  # Holds the Codex adapter to the shared adapter conformance suite — harness's
  # second real adapter, and the first proof the `AgentAdapter` contract is not
  # Claude-shaped. The whole suite is injected by `use`; Codex-specific
  # assertions (argv composition, the autonomous mapping, the `exec`/`exec
  # resume` subcommand swap) live in `Harness.AgentAdapter.CodexTest`.
  use Harness.AgentAdapter.ConformanceCase, adapter: Harness.AgentAdapter.Codex
end
