defmodule Harness.DependencyBump.Provider.Rust do
  @moduledoc """
  Rust dependency-bump prompt provider.
  """

  use Harness.DependencyBump.Provider,
    check_command: "cargo test",
    files_to_modify: ["Cargo.toml", "Cargo.lock"]

  @spec body([Row.t()], :minor_patch | :major) :: String.t()
  defp body(rows, kind) do
    """
    Update the Rust dependencies named in the ground-truth freshness facts below.

    Ground-truth dependency freshness facts:

    #{Common.facts_table(rows)}

    These facts come from harness dependency freshness providers. Do not claim a dependency cannot be updated when this table names it as outdated.

    Work in `Cargo.toml` and `Cargo.lock`. Use Cargo's normal update flow for these dependencies and keep unrelated dependency changes out of the diff.

    Reviewer check command for this dependency bump: `#{@check_command}`.

    #{kind_instruction(kind)}
    """
  end

  @spec acceptance_criteria(:minor_patch | :major) :: [String.t()]
  defp acceptance_criteria(_kind) do
    [
      "The listed Rust dependency bump is applied in Cargo.toml and Cargo.lock as needed.",
      "Required code changes for the dependency upgrade are made.",
      "No unrelated dependency upgrades are included."
    ]
  end

  @spec kind_instruction(:minor_patch | :major) :: String.t()
  defp kind_instruction(:minor_patch), do: "Batch these minor/patch bumps in this one task."
  defp kind_instruction(:major), do: "This task is intentionally scoped to one major-version bump."
end
