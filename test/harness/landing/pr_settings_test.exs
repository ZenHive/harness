defmodule Harness.Landing.PRSettingsTest do
  @moduledoc """
  `:pr` landing-policy overlay: `set/4` requires a target branch, `describe/1`
  renders the PR phrase, and a persisted override round-trips on a fresh read.
  """
  use ExUnit.Case, async: false

  alias Harness.Landing.Settings, as: LandingSettings
  alias Harness.Project
  alias Harness.Test.SettingsStoreMemory

  @scope :test_default

  setup do
    SettingsStoreMemory.reset(scope: @scope)
    on_exit(fn -> SettingsStoreMemory.reset(scope: @scope) end)
    {:ok, project: project("pr-demo")}
  end

  test "set/4 accepts :pr with a non-empty target_branch", %{project: project} do
    assert :ok = LandingSettings.set(project.name, :pr, "development", "test")
    overlaid = LandingSettings.overlay(project)
    assert overlaid.landing_policy == :pr
    assert overlaid.target_branch == "development"
  end

  test "set/4 refuses :pr without a target_branch", %{project: project} do
    assert {:error, :target_branch_required} = LandingSettings.set(project.name, :pr, "", "test")
    assert {:error, :target_branch_required} = LandingSettings.set(project.name, :pr, nil, "test")
    assert LandingSettings.overlay(project).landing_policy == :manual
  end

  test "describe/1 renders pull request to <branch>" do
    assert LandingSettings.describe(%{landing_policy: :pr, target_branch: "main"}) ==
             "pull request to main"
  end

  test "a persisted :pr overlay survives a fresh read (node restart)", %{project: project} do
    assert :ok = LandingSettings.set(project.name, :pr, "release", "test")
    assert LandingSettings.overlay(project).landing_policy == :pr
    assert LandingSettings.overlay(project).target_branch == "release"
  end

  @spec project(String.t()) :: Project.t()
  defp project(name) do
    %Project{
      name: name,
      source: {:local, "/tmp/#{name}"},
      roadmap_path: "/tmp/#{name}",
      languages: [:elixir]
    }
  end
end
