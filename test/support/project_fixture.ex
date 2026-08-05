defmodule Harness.ProjectFixture do
  @moduledoc false

  alias Harness.Project

  @spec from_repo(String.t(), keyword()) :: Project.t()
  def from_repo(repo, opts \\ []) do
    name = Keyword.get(opts, :name, Path.basename(repo))

    %Project{
      name: name,
      source: {:local, repo},
      check_command: Keyword.get(opts, :check_command),
      languages: Keyword.get(opts, :languages, [Keyword.get(opts, :language, :elixir)]),
      roadmap_path: Keyword.get(opts, :roadmap_path, repo),
      roadmap_target_branch: Keyword.get(opts, :roadmap_target_branch),
      concurrency_cap: Keyword.get(opts, :concurrency_cap),
      landing_policy: Keyword.get(opts, :landing_policy, :manual),
      target_branch: Keyword.get(opts, :target_branch),
      pollution_allowlist: Keyword.get(opts, :pollution_allowlist),
      warm_paths: Keyword.get(opts, :warm_paths, []),
      reviewer: Keyword.get(opts, :reviewer),
      test_db_isolation_env: Keyword.get(opts, :test_db_isolation_env),
      tooling_baseline_overrides: Keyword.get(opts, :tooling_baseline_overrides, %{})
    }
  end
end
