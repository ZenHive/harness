defmodule Harness.ProjectRegistry.PersistenceTest do
  @moduledoc """
  Integration tests for Postgres-backed runtime project registration (Task 141).

  Requires a migrated test DB: `MIX_ENV=test mix ecto.create ecto.migrate`
  Run with `mix test.json --include integration`.
  """
  use Harness.DataCase, async: false

  alias Harness.Oban, as: HarnessOban
  alias Harness.Project
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.ProjectRegistry.Persistence
  alias Harness.ProjectRegistry.Schema.Project, as: ProjectSchema
  alias Harness.Repo

  @moduletag :integration

  @eventually_tries 100
  @eventually_delay_ms 20

  setup do
    prev_repo_enabled = Application.get_env(:harness, :repo_enabled)
    prev_projects = Application.get_env(:harness, :projects)

    Application.put_env(:harness, :repo_enabled, true)
    Application.put_env(:harness, :projects, [])

    on_exit(fn ->
      Application.put_env(:harness, :repo_enabled, prev_repo_enabled)
      Application.put_env(:harness, :projects, prev_projects)
    end)

    Repo.delete_all(ProjectSchema)
    ProjectRegistry.reset()

    :ok
  end

  describe "runtime registration survives BEAM restart" do
    test "register/1 is restored after clearing memory and reloading persisted state" do
      name = "persist-#{System.unique_integer([:positive])}"
      project = ProjectFixture.from_repo("/tmp/#{name}", name: name)

      assert :ok = ProjectRegistry.register(project)
      assert :ok = ProjectRegistry.reset()
      assert :ok = ProjectRegistry.reload_persisted_state()

      assert {:ok, ^project} = ProjectRegistry.lookup(name)
    end

    test "unregister/1 removes the persisted row so it does not reappear on reload" do
      name = "gone-#{System.unique_integer([:positive])}"
      project = ProjectFixture.from_repo("/tmp/#{name}", name: name)

      assert :ok = ProjectRegistry.register(project)
      assert :ok = ProjectRegistry.unregister(name)
      assert :ok = ProjectRegistry.reload_persisted_state()

      assert {:error, {:unknown_project, ^name}} = ProjectRegistry.lookup(name)
    end

    test "roundtrips complex project fields through term_to_binary" do
      name = "complex-#{System.unique_integer([:positive])}"

      project = %Project{
        name: name,
        source: {:github, "https://github.com/example/demo.git"},
        check_command: "mix precommit",
        roadmap_path: "/tmp/#{name}/roadmap/tasks.toml",
        concurrency_cap: 4,
        landing_policy: :auto,
        target_branch: "development",
        warm_paths: ["priv/foo", "priv/discoveries"]
      }

      assert :ok = ProjectRegistry.register(project)
      assert :ok = ProjectRegistry.reset()
      assert :ok = ProjectRegistry.reload_persisted_state()

      assert {:ok, restored} = ProjectRegistry.lookup(name)
      assert restored.source == project.source
      assert restored.check_command == "mix precommit"
      assert restored.concurrency_cap == 4
      assert restored.landing_policy == :auto
      assert restored.target_branch == "development"
      assert restored.warm_paths == ["priv/foo", "priv/discoveries"]
    end
  end

  describe "config-declared projects are first-boot seeds" do
    setup do
      prior = Application.get_env(:harness, :projects)

      on_exit(fn ->
        Application.put_env(:harness, :projects, prior)
      end)

      :ok
    end

    test "reload imports a config project when no persisted row exists" do
      name = "seed-#{System.unique_integer([:positive])}"

      config_entry = [
        name: name,
        source: {:local, "/tmp/config-#{name}"},
        check_command: "mix precommit",
        roadmap_path: "/tmp/config-#{name}/roadmap/tasks.toml"
      ]

      Application.put_env(:harness, :projects, [config_entry])

      assert :ok = ProjectRegistry.reload_persisted_state()

      assert {:ok, %Project{roadmap_path: config_path}} = ProjectRegistry.lookup(name)
      assert config_path == Path.expand("/tmp/config-#{name}/roadmap/tasks.toml")
      assert %ProjectSchema{name: ^name} = Repo.get(ProjectSchema, name)
    end

    test "reload keeps an existing persisted row over config with the same name" do
      name = "conflict-#{System.unique_integer([:positive])}"

      persisted =
        ProjectFixture.from_repo("/tmp/persisted-#{name}", name: name, roadmap_path: "/tmp/persisted")

      config_entry = [
        name: name,
        source: {:local, "/tmp/config-#{name}"},
        check_command: "mix precommit",
        roadmap_path: "/tmp/config-#{name}/roadmap/tasks.toml"
      ]

      assert :ok = Persistence.upsert(persisted)
      Application.put_env(:harness, :projects, [config_entry])

      assert :ok = ProjectRegistry.reload_persisted_state()

      assert {:ok, %Project{roadmap_path: config_path}} = ProjectRegistry.lookup(name)
      assert config_path == persisted.roadmap_path
      refute config_path == Path.expand("/tmp/config-#{name}/roadmap/tasks.toml")
    end
  end

  describe "structural schema drift is not swallowed" do
    test "list/0 re-raises an undefined_column error instead of returning []" do
      # Drop the column the schema references; the sandbox transaction rolls this
      # back on exit. A blanket rescue would hide this as an empty registry — the
      # exact 2026-06-11 warm_paths incident — so it must propagate.
      Repo.query!("ALTER TABLE projects DROP COLUMN warm_paths")

      assert_raise Postgrex.Error, fn -> Persistence.list() end
    end

    test "upsert/1 re-raises an undefined_column error instead of returning :ok" do
      project = ProjectFixture.from_repo("/tmp/drift", name: "drift-#{System.unique_integer([:positive])}")

      Repo.query!("ALTER TABLE projects DROP COLUMN warm_paths")

      assert_raise Postgrex.Error, fn -> Persistence.upsert(project) end
    end
  end

  describe "restored registrations bootstrap Oban queues at boot" do
    setup do
      prev_oban = Application.get_env(:harness, Oban)

      Application.put_env(:harness, Oban,
        name: HarnessOban,
        repo: Repo,
        notifier: Oban.Notifiers.Isolated,
        stage_interval: :infinity,
        queues: [],
        plugins: false
      )

      start_supervised!({Oban, Application.get_env(:harness, Oban)})

      on_exit(fn -> Application.put_env(:harness, Oban, prev_oban) end)

      :ok
    end

    test "reload ensures dispatch and landing queues for persisted projects" do
      name = "boot-queue-#{System.unique_integer([:positive])}"
      project = ProjectFixture.from_repo("/tmp/#{name}", name: name, concurrency_cap: 2)

      assert :ok = ProjectRegistry.register(project)
      assert :ok = ProjectRegistry.reset()
      assert :ok = ProjectRegistry.reload_persisted_state()

      assert {:ok, ^project} = ProjectRegistry.lookup(name)

      assert_eventually(fn ->
        running = HarnessOban |> Oban.check_all_queues() |> MapSet.new(& &1.queue)

        assert MapSet.member?(running, HarnessOban.queue_name(project))
        assert MapSet.member?(running, HarnessOban.landing_queue_name(project))
      end)
    end
  end

  defp assert_eventually(fun, tries \\ @eventually_tries)

  defp assert_eventually(fun, tries) when tries > 1 do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(@eventually_delay_ms)
      assert_eventually(fun, tries - 1)
  end

  defp assert_eventually(fun, 1), do: fun.()
end
