defmodule Harness.ToolingBaseline do
  @moduledoc """
  Mechanical tooling-baseline conformance fact capture for registered projects.

  Providers keyed on `project.language` compare committed project surface against
  harness-shipped manifests; this module records raw drift facts for the
  dashboard. Harness never installs tooling, never mutates projects, and never
  gates dispatch on conformance.
  """

  alias Harness.Project
  alias Harness.ToolingBaseline.Providers
  alias Harness.ToolingBaseline.Snapshot

  require Logger

  @doc "Scans one project with its language baseline provider."
  @spec scan_project(Project.t(), String.t(), keyword()) :: {:ok, Snapshot.t()} | {:skipped, term()} | {:error, term()}
  def scan_project(%Project{} = project, repo_path, opts \\ []) when is_binary(repo_path) and is_list(opts) do
    provider_opts = Keyword.get(opts, :provider_opts, [])

    with {:ok, provider} <- Providers.resolve(project),
         {:ok, %Snapshot{} = snapshot} <- provider.scan(project, repo_path, provider_opts) do
      {:ok, snapshot}
    else
      {:skipped, reason} = skipped ->
        Logger.debug("harness tooling baseline: skipped #{project.name}: #{inspect(reason)}")
        skipped

      {:error, reason} = error ->
        Logger.warning("harness tooling baseline: failed #{project.name}: #{inspect(reason)}")
        error
    end
  end
end
