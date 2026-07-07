defmodule Harness.DependencyBump.Provider.Go do
  @moduledoc """
  Go dependency-bump prompt provider.
  """

  @behaviour Harness.DependencyBump.Provider

  alias Harness.DependencyBump.Provider.Common
  alias Harness.DepFreshness.Row

  @check_command "go test ./..."
  @files_to_modify ["go.mod", "go.sum"]

  @impl Harness.DependencyBump.Provider
  @spec build(atom(), [Row.t()]) :: [Harness.DependencyBump.TaskSpec.t()]
  def build(language, rows) when is_atom(language) and is_list(rows) do
    Common.specs(language, rows,
      title: & &1,
      body: &body/2,
      acceptance_criteria: &acceptance_criteria/1,
      files_to_modify: @files_to_modify,
      check_command: @check_command
    )
  end

  @spec body([Row.t()], :minor_patch | :major) :: String.t()
  defp body(rows, kind) do
    """
    Update the Go dependencies named in the ground-truth freshness facts below.

    Ground-truth dependency freshness facts:

    #{Common.facts_table(rows)}

    These facts come from harness dependency freshness providers. Do not claim a dependency cannot be updated when this table names it as outdated.

    Work in `go.mod` and `go.sum`. Use Go's normal module update flow for these dependencies and keep unrelated dependency changes out of the diff.

    Reviewer check command for this dependency bump: `#{@check_command}`.

    #{kind_instruction(kind)}
    """
  end

  @spec acceptance_criteria(:minor_patch | :major) :: [String.t()]
  defp acceptance_criteria(_kind) do
    [
      "The listed Go dependency bump is applied in go.mod and go.sum.",
      "Required code changes for the dependency upgrade are made.",
      "No unrelated dependency upgrades are included."
    ]
  end

  @spec kind_instruction(:minor_patch | :major) :: String.t()
  defp kind_instruction(:minor_patch), do: "Batch these minor/patch bumps in this one task."
  defp kind_instruction(:major), do: "This task is intentionally scoped to one major-version bump."
end
