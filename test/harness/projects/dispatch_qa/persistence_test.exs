defmodule Harness.Projects.DispatchQA.PersistenceTest do
  use Harness.DataCase, async: false

  alias Harness.Landing.Settings
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.ProjectRegistry.Schema.Project, as: ProjectSchema
  alias Harness.Projects.DispatchQA

  @moduletag :integration

  setup do
    previous = Application.get_env(:harness, :repo_enabled)
    Application.put_env(:harness, :repo_enabled, true)
    on_exit(fn -> Application.put_env(:harness, :repo_enabled, previous) end)
    project = ProjectFixture.from_repo("/tmp/qa-readback", name: "qa-readback-#{System.unique_integer([:positive])}")
    assert :ok = ProjectRegistry.upsert(project)
    on_exit(fn -> ProjectRegistry.unregister(project.name) end)
    %{project: project}
  end

  test "readback detects durable write loss despite a healthy runtime registry", %{project: project} do
    assert {:ok, ^project} = DispatchQA.persisted_lookup(project.name)
    row = Repo.get!(ProjectSchema, project.name)
    Repo.delete!(row)
    assert {:ok, ^project} = ProjectRegistry.lookup(project.name)
    assert {:error, :not_persisted} = DispatchQA.persisted_lookup(project.name)
  end

  test "landing overrides do not corrupt registration readback", %{project: project} do
    assert :ok = Settings.set(project.name, :auto, "release", "test")
    assert {:ok, %{landing_policy: :auto, target_branch: "release"}} = ProjectRegistry.lookup(project.name)
    assert {:ok, ^project} = DispatchQA.persisted_lookup(project.name)
    assert :ok = ProjectRegistry.upsert(%{project | check_command: "focused checks"})
    assert {:ok, %{target_branch: "release", check_command: "focused checks"}} = ProjectRegistry.lookup(project.name)
  end

  test "readback detects settings drift and treats warm_paths column as authoritative", %{project: project} do
    row = Repo.get!(ProjectSchema, project.name)
    row |> Ecto.Changeset.change(warm_paths: ["deps"]) |> Repo.update!()
    assert {:error, :persistence_mismatch} = DispatchQA.persisted_lookup(project.name)
    assert :ok = ProjectRegistry.upsert(%{project | warm_paths: ["deps"]})
    assert {:ok, %{warm_paths: ["deps"]}} = DispatchQA.persisted_lookup(project.name)
  end
end
