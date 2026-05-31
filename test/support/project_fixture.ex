defmodule Harness.ProjectFixture do
  @moduledoc false

  alias Harness.CheckStack.Preset.Elixir, as: ElixirPreset
  alias Harness.Project

  @spec from_repo(String.t(), keyword()) :: Project.t()
  def from_repo(repo, opts \\ []) do
    name = Keyword.get(opts, :name, Path.basename(repo))

    %Project{
      name: name,
      source: {:local, repo},
      check_stacks: check_stacks(opts),
      roadmap_path: Keyword.get(opts, :roadmap_path, repo),
      concurrency_cap: Keyword.get(opts, :concurrency_cap),
      landing_policy: Keyword.get(opts, :landing_policy, :manual),
      semantic_gate: Keyword.get(opts, :semantic_gate, :auto_land_only)
    }
  end

  # Accepts a `:check_stacks` list directly, or a singular `:check_stack`
  # convenience that wraps into a one-element list; defaults to the Elixir
  # preset at the repo root.
  @spec check_stacks(keyword()) :: [Harness.CheckStack.t()]
  defp check_stacks(opts) do
    cond do
      is_list(Keyword.get(opts, :check_stacks)) -> Keyword.fetch!(opts, :check_stacks)
      Keyword.has_key?(opts, :check_stack) -> [Keyword.fetch!(opts, :check_stack)]
      true -> [ElixirPreset.preset()]
    end
  end
end
