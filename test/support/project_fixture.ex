defmodule Harness.ProjectFixture do
  @moduledoc false

  alias Harness.CheckStack
  alias Harness.Project
  alias Harness.Verification.Check

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
      # The PRODUCT default is true (every green verdict gets a reviewer pass —
      # %Project{} defstruct). The FIXTURE default is false for hermeticity:
      # green-settling tests must not spawn a real cross-family reviewer agent
      # installed on the host. Tests that exercise green review opt in with
      # `review_green: true` plus a reviewer test double.
      review_green: Keyword.get(opts, :review_green, false)
    }
  end

  # Accepts a `:check_stacks` list directly, or a singular `:check_stack`
  # convenience that wraps into a one-element list; defaults to a neutral
  # always-green stack with no setup. The fixture repo is a README-only git
  # repo, not an Elixir project, so the Elixir preset's setup/checks could
  # never legitimately run against it — tests that exercise verification
  # behavior pass their own checks or stacks explicitly.
  @spec check_stacks(keyword()) :: [CheckStack.t()]
  defp check_stacks(opts) do
    cond do
      is_list(Keyword.get(opts, :check_stacks)) -> Keyword.fetch!(opts, :check_stacks)
      Keyword.has_key?(opts, :check_stack) -> [Keyword.fetch!(opts, :check_stack)]
      true -> [%CheckStack{name: :fixture, checks: [%Check{name: "ok", command: "true", args: []}]}]
    end
  end
end
