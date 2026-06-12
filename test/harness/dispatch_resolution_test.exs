defmodule Harness.DispatchResolutionTest do
  # async: false because these register a project in the global ProjectRegistry and
  # reset it in setup, mirroring Harness.Batch.AgentEvaluationTest.
  use ExUnit.Case, async: false

  alias Harness.Dispatch
  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry

  setup do
    ProjectRegistry.reset()
    project = ProjectFixture.from_repo(GitFixture.init_repo())
    :ok = ProjectRegistry.register(project)
    {:ok, project: project}
  end

  # With a registered project, adapter + project resolution succeed and the
  # dispatch tools proceed into rmap ingestion. The fixture repo has no roadmap,
  # so ingestion fails downstream — proving the path ran *past* resolution
  # (lookup_project success, selector/1, the Roadmap call) rather than bailing on
  # an unknown adapter/project. The exact rmap failure reason varies by whether
  # `rmap` is on PATH, so the assertion pins "got past resolution", not the reason.
  describe "compare/4 past resolution" do
    test "reaches rmap ingestion for the next task on a registered project", %{project: project} do
      assert {:error, reason} = Dispatch.compare(project.name, "next", ["claude"])

      refute reason == :no_adapters
      refute match?({:unknown_adapter, _}, reason)
      refute match?({:unknown_project, _}, reason)
    end

    test "reaches rmap ingestion for a task id on a registered project", %{project: project} do
      assert {:error, reason} = Dispatch.compare(project.name, "25", ["claude", "codex"])

      refute reason == :no_adapters
      refute match?({:unknown_adapter, _}, reason)
      refute match?({:unknown_project, _}, reason)
    end
  end

  describe "bundle/2 past resolution" do
    test "reaches rmap next-bundle on a registered project", %{project: project} do
      assert {:error, reason} = Dispatch.bundle(project.name, "claude")

      refute match?({:unknown_adapter, _}, reason)
      refute match?({:non_delegatable_adapter, _}, reason)
      refute match?({:unknown_project, _}, reason)
    end
  end
end
