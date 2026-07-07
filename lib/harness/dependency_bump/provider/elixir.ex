defmodule Harness.DependencyBump.Provider.Elixir do
  @moduledoc """
  Elixir dependency-bump prompt provider.
  """

  @behaviour Harness.DependencyBump.Provider

  alias Harness.DependencyBump.Provider.Common
  alias Harness.DepFreshness.Row

  @check_command "mix test.json --quiet --all --include integration"
  @files_to_modify ["mix.exs", "mix.lock"]

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
    Update the Elixir dependencies named in the ground-truth freshness facts below.

    Ground-truth dependency freshness facts:

    #{Common.facts_table(rows)}

    These facts come from harness dependency freshness providers. Do not claim a dependency cannot be updated when this table names it as outdated.

    Work in `mix.exs` and `mix.lock`. Use `mix deps.update #{Common.dependency_names(rows)}` or the smallest equivalent Mix command needed for these dependencies. Keep unrelated dependency changes out of the diff.

    For same-major updates where the table says `Constraint allowed` is `no`, treat that as an over-tight library-style pin: widen the constraint in `mix.exs` to idiomatic `~> x.y` and let `mix.lock` plus the reviewer suite control the resolved version. Do not declare that dependency blocked for this reason.

    Reviewer check command for this dependency bump: `#{@check_command}`. It includes `mix test.json --include integration`; the reviewer runs it, not harness.

    #{kind_instruction(kind)}
    """
  end

  @spec acceptance_criteria(:minor_patch | :major) :: [String.t()]
  defp acceptance_criteria(:minor_patch) do
    [
      "All listed Elixir minor/patch dependency bumps are applied in mix.exs and mix.lock.",
      "Same-major over-tight pins are widened to idiomatic ~> x.y instead of being treated as blocked.",
      "No unrelated dependency upgrades are included."
    ]
  end

  defp acceptance_criteria(:major) do
    [
      "The named Elixir major-version dependency bump is applied in mix.exs and mix.lock.",
      "Required code changes for the major upgrade are made.",
      "No unrelated dependency upgrades are included."
    ]
  end

  @spec kind_instruction(:minor_patch | :major) :: String.t()
  defp kind_instruction(:minor_patch), do: "Batch these constraint-satisfiable minor/patch bumps in this one task."
  defp kind_instruction(:major), do: "This task is intentionally scoped to one major-version bump."
end
