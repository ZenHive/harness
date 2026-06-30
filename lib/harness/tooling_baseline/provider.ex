defmodule Harness.ToolingBaseline.Provider do
  @moduledoc """
  Behaviour for per-language tooling-baseline providers.

  Each provider compares a project's committed surface against a harness-shipped
  manifest and returns raw conformance items — no judgment, no mutation.
  """

  alias Harness.Project
  alias Harness.ToolingBaseline.Snapshot

  @doc "Scans one project checkout and returns raw baseline conformance facts."
  @callback scan(Project.t(), String.t(), keyword()) ::
              {:ok, Snapshot.t()} | {:error, term()} | {:skipped, term()}
end
