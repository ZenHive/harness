defmodule Harness.Landing.SettingsTest do
  @moduledoc """
  Unit coverage for `Harness.Landing.Settings` — the persisted, runtime-flippable
  per-project landing override that backs the dashboard's Landing card. Reads and
  writes go straight to the one Postgres settings store (the in-memory test
  backend stands in for Postgres here).

  `async: false` — shares the global test settings store scope, reset per test.
  """

  # async: false because tests reset the shared in-memory settings store scope.
  use ExUnit.Case, async: false

  alias Harness.Landing.Settings, as: LandingSettings
  alias Harness.Project
  alias Harness.SettingsStore
  alias Harness.Test.SettingsStoreMemory

  @scope :test_default

  setup do
    SettingsStoreMemory.reset(scope: @scope)
    on_exit(fn -> SettingsStoreMemory.reset(scope: @scope) end)

    {:ok, project: project("demo")}
  end

  describe "overlay/1" do
    test "returns the project unchanged when no override exists", %{project: project} do
      assert LandingSettings.overlay(project) == project
    end

    test "applies a persisted :auto override onto the project", %{project: project} do
      :ok = LandingSettings.set(project.name, :auto, "release", "test")

      overlaid = LandingSettings.overlay(project)
      assert overlaid.landing_policy == :auto
      assert overlaid.target_branch == "release"
    end

    test "an override for a different project does not leak", %{project: project} do
      :ok = LandingSettings.set("other", :auto, "main", "test")
      assert LandingSettings.overlay(project) == project
    end

    test "applies a persisted reviewer override onto the project", %{project: project} do
      :ok = LandingSettings.set_reviewer(project.name, :codex, "test")

      assert LandingSettings.overlay(project).reviewer == :codex
    end

    test "an explicit nil reviewer override clears the registration default", %{project: project} do
      registered = %{project | reviewer: :codex}
      :ok = LandingSettings.set_reviewer(project.name, nil, "test")

      assert LandingSettings.overlay(registered).reviewer == nil
    end
  end

  describe "overlay_many/1" do
    test "returns [] for empty input", %{project: _project} do
      assert LandingSettings.overlay_many([]) == []
    end

    test "produces identical results to mapping overlay/1 (semantics preserved)", %{project: project} do
      p2 = project("batch2")
      :ok = LandingSettings.set(project.name, :auto, "release", "test")
      :ok = LandingSettings.set_reviewer("batch2", :codex, "test")

      batched = LandingSettings.overlay_many([project, p2])
      mapped = [LandingSettings.overlay(project), LandingSettings.overlay(p2)]

      assert batched == mapped
      assert hd(batched).landing_policy == :auto
      assert hd(batched).target_branch == "release"
      assert List.last(batched).reviewer == :codex
    end

    test "no overrides: returns projects unchanged (order preserved)", %{project: project} do
      p2 = project("plain2")
      assert LandingSettings.overlay_many([project, p2]) == [project, p2]
    end

    test "2-arity applies the supplied snapshot without rereading the store", %{project: project} do
      :ok = LandingSettings.set(project.name, :auto, "release", "test")

      assert LandingSettings.overlay(project, %{}) == project
      assert LandingSettings.overlay_many([project], %{}) == [project]

      snapshot = %{project.name => %{landing_policy: :auto, target_branch: "main"}}
      overlaid = LandingSettings.overlay(project, snapshot)
      assert overlaid.landing_policy == :auto
      assert overlaid.target_branch == "main"
    end
  end

  describe "set/4" do
    test "refuses :auto without a target branch", %{project: project} do
      assert {:error, :target_branch_required} = LandingSettings.set(project.name, :auto, nil, "test")
      assert {:error, :target_branch_required} = LandingSettings.set(project.name, :auto, "   ", "test")
      # The rejected set never armed the project.
      assert LandingSettings.overlay(project).landing_policy == :manual
    end

    test "trims the target branch", %{project: project} do
      :ok = LandingSettings.set(project.name, :auto, "  develop  ", "test")
      assert LandingSettings.overlay(project).target_branch == "develop"
    end

    test ":manual clears the target branch", %{project: project} do
      :ok = LandingSettings.set(project.name, :auto, "release", "test")
      :ok = LandingSettings.set(project.name, :manual, "release", "test")

      overlaid = LandingSettings.overlay(project)
      assert overlaid.landing_policy == :manual
      assert overlaid.target_branch == nil
    end

    test "rejects an unknown policy", %{project: project} do
      assert {:error, :invalid_policy} = LandingSettings.set(project.name, :bogus, "main", "test")
    end
  end

  describe "effective/1" do
    test "reflects the project's own values when no override is set", %{project: project} do
      armed = %{project | landing_policy: :auto, target_branch: "main", reviewer: :codex}
      assert LandingSettings.effective(armed) == %{landing_policy: :auto, target_branch: "main", reviewer: :codex}
    end

    test "reflects the override over the project default", %{project: project} do
      armed = %{project | landing_policy: :auto, target_branch: "main", reviewer: :codex}
      :ok = LandingSettings.set(project.name, :manual, nil, "test")
      :ok = LandingSettings.set_reviewer(project.name, nil, "test")

      assert LandingSettings.effective(armed) == %{landing_policy: :manual, target_branch: nil, reviewer: nil}
    end
  end

  describe "persistence" do
    test "a flip survives a restart (the silent-revert regression)", %{project: project} do
      :ok = LandingSettings.set(project.name, :auto, "ship", "test")
      # No app-env cache to clear: the store is the source of truth, so a fresh
      # read (as a restarted node would do) returns the persisted override.
      assert LandingSettings.overlay(project).target_branch == "ship"
      assert LandingSettings.overlay(project).landing_policy == :auto
    end

    test "a reviewer flip survives a restart", %{project: project} do
      :ok = LandingSettings.set_reviewer(project.name, :codex, "test")
      assert LandingSettings.overlay(project).reviewer == :codex
    end

    test "overlay sanitizes a malformed persisted entry", %{project: project} do
      good = %{landing_policy: :auto, target_branch: "ship", reviewer: :codex}
      # Hand-write a torn record with one good and one malformed entry straight
      # into the store, bypassing the validated setters.
      torn = %{project.name => good, "junk" => :not_a_map}
      assert :ok = SettingsStore.put(:landing, torn)

      assert LandingSettings.overlay(project).target_branch == "ship"
      assert LandingSettings.overlay(project).reviewer == :codex
      assert LandingSettings.overlay(project("junk")) == project("junk")
    end

    test "with repo disabled, a flip is a no-op (ephemeral)", %{project: project} do
      prior = Application.get_env(:harness, :settings_store)
      Application.put_env(:harness, :settings_store, false)
      on_exit(fn -> restore(:settings_store, prior) end)

      :ok = LandingSettings.set(project.name, :auto, "ship", "test")
      # The no-op store discards the write; overlay returns the registration default.
      assert LandingSettings.overlay(project).landing_policy == :manual
    end
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

  @spec restore(atom(), term()) :: :ok
  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)
end
