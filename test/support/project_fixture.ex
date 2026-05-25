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
      check_stack: Keyword.get(opts, :check_stack, ElixirPreset.preset()),
      roadmap_path: Keyword.get(opts, :roadmap_path, repo),
      concurrency_cap: Keyword.get(opts, :concurrency_cap)
    }
  end
end
