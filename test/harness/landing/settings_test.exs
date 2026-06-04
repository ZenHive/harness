defmodule Harness.Landing.SettingsTest do
  @moduledoc """
  Unit coverage for `Harness.Landing.Settings` — the persisted, runtime-flippable
  per-project landing override that backs the dashboard's Landing card.

  `async: false` — reads/writes the global `:harness, :landing_overrides` app env
  and a term file under a temp root, which would leak across parallel tests.
  """

  use ExUnit.Case, async: false

  alias Harness.Landing.Settings, as: LandingSettings
  alias Harness.Project
  alias Harness.TermCodec

  @env_key :landing_overrides

  setup do
    prior_env = Application.get_env(:harness, @env_key)
    prior_store = Application.get_env(:harness, :landing_settings)
    root = Path.join(System.tmp_dir!(), "landing-settings-test-#{System.unique_integer([:positive])}")
    Application.put_env(:harness, :landing_settings, root: root)
    Application.put_env(:harness, @env_key, %{})

    on_exit(fn ->
      restore(@env_key, prior_env)
      restore(:landing_settings, prior_store)
      File.rm_rf(root)
    end)

    {:ok, root: root, project: project("demo")}
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
    test "set/4 write-throughs so load_into_env/0 restores the override", %{project: project} do
      :ok = LandingSettings.set(project.name, :auto, "ship", "test")
      # Simulate a restart: clear the live cache, reseed from the file.
      Application.put_env(:harness, @env_key, %{})
      :ok = LandingSettings.load_into_env()

      assert LandingSettings.overlay(project).target_branch == "ship"
    end

    test "set_reviewer/3 write-throughs so load_into_env/0 restores the override", %{project: project} do
      :ok = LandingSettings.set_reviewer(project.name, :codex, "test")
      Application.put_env(:harness, @env_key, %{})
      :ok = LandingSettings.load_into_env()

      assert LandingSettings.overlay(project).reviewer == :codex
    end

    test "load_into_env/0 sanitizes a malformed persisted entry", %{root: root, project: project} do
      :ok = LandingSettings.set(project.name, :auto, "ship", "test")
      # Hand-write a torn record with one good and one malformed entry.
      bad = %{project.name => %{landing_policy: :auto, target_branch: "ship", reviewer: :codex}, "junk" => :not_a_map}
      path = Path.join(root, "harness_settings.term")
      assert :ok = TermCodec.write_file(path, %{"landing" => bad})

      Application.put_env(:harness, @env_key, %{})
      :ok = LandingSettings.load_into_env()

      assert LandingSettings.overlay(project).target_branch == "ship"
      assert LandingSettings.overlay(project).reviewer == :codex
      assert LandingSettings.overlay(project("junk")) == project("junk")
    end

    test "a disabled store flips at runtime but writes nothing", %{root: root, project: project} do
      Application.put_env(:harness, :landing_settings, false)

      :ok = LandingSettings.set(project.name, :auto, "ship", "test")
      # Runtime flip took effect…
      assert LandingSettings.overlay(project).landing_policy == :auto
      :ok = LandingSettings.set_reviewer(project.name, :codex, "test")
      assert LandingSettings.overlay(project).reviewer == :codex
      # …but no file was written.
      refute File.exists?(Path.join(root, "landing_settings.term"))
    end
  end

  @spec project(String.t()) :: Project.t()
  defp project(name) do
    %Project{
      name: name,
      source: {:local, "/tmp/#{name}"},
      roadmap_path: "/tmp/#{name}"
    }
  end

  @spec restore(atom(), term()) :: :ok
  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)
end
