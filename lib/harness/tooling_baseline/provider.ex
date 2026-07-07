defmodule Harness.ToolingBaseline.Provider do
  @moduledoc """
  Behaviour for per-language tooling-baseline providers.

  Each provider compares a project's committed surface against a harness-shipped
  manifest and returns raw conformance items — no judgment, no mutation.
  """

  alias Harness.Project
  alias Harness.ToolingBaseline.Snapshot
  alias Harness.ToolingBaseline.TaskSpec

  @doc "Scans one project checkout and returns raw baseline conformance facts."
  @callback scan(Project.t(), String.t(), keyword()) ::
              {:ok, Snapshot.t()} | {:error, term()} | {:skipped, term()}

  @doc "Builds the operator-triggered install task from stored conformance facts."
  @callback build_task_spec(Project.t(), Snapshot.t(), keyword()) :: TaskSpec.t() | nil
end
