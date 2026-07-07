defmodule Harness.DependencyBump.Provider.JavaScript do
  @moduledoc """
  JavaScript and TypeScript dependency-bump prompt provider.
  """

  use Harness.DependencyBump.Provider,
    check_command: "npm test",
    files_to_modify: ["package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock"]

  @spec body([Row.t()], :minor_patch | :major) :: String.t()
  defp body(rows, kind) do
    """
    Update the JavaScript/TypeScript dependencies named in the ground-truth freshness facts below.

    Ground-truth dependency freshness facts:

    #{Common.facts_table(rows)}

    These facts come from harness dependency freshness providers. Do not claim a dependency cannot be updated when this table names it as outdated.

    Work in `package.json` and the committed lockfile for the package manager this project uses. Keep unrelated dependency changes out of the diff.

    Reviewer check command for this dependency bump: `#{@check_command}`.

    #{kind_instruction(kind)}
    """
  end

  @spec acceptance_criteria(:minor_patch | :major) :: [String.t()]
  defp acceptance_criteria(_kind) do
    [
      "The listed JavaScript/TypeScript dependency bump is applied in package.json and the committed lockfile.",
      "Required code changes for the dependency upgrade are made.",
      "No unrelated dependency upgrades are included."
    ]
  end

  @spec kind_instruction(:minor_patch | :major) :: String.t()
  defp kind_instruction(:minor_patch), do: "Batch these minor/patch bumps in this one task."
  defp kind_instruction(:major), do: "This task is intentionally scoped to one major-version bump."
end
