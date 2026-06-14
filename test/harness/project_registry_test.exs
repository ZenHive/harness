defmodule Harness.ProjectRegistryTest do
  # async: false because tests reset and mutate the singleton ProjectRegistry.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Harness.Dispatch
  alias Harness.GitFixture
  alias Harness.Landing.Settings, as: LandingSettings
  alias Harness.Oban, as: HarnessOban
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.ProjectRegistry.Schema.Project, as: ProjectSchema
  alias Harness.Repo
  alias Harness.Roadmap.Item
  alias Harness.Run.Result
  alias Harness.Run.Supervisor, as: RunSupervisor
  alias Harness.Test.SettingsStoreMemory

  @eventually_tries 100
  @eventually_delay_ms 20

  setup do
    ProjectRegistry.reset()
    :ok
  end

  describe "register/1, lookup/1, list/0, unregister/1" do
    test "registers and looks up a project by name" do
      project = sample_project("alpha")

      assert :ok = ProjectRegistry.register(project)
      assert {:ok, ^project} = ProjectRegistry.lookup("alpha")
      assert [^project] = ProjectRegistry.list()
    end

    test "rejects duplicate names" do
      assert :ok = ProjectRegistry.register(sample_project("alpha"))
      assert {:error, {:duplicate, "alpha"}} = ProjectRegistry.register(sample_project("alpha"))
    end

    test "unregister/1 removes a project" do
      assert :ok = ProjectRegistry.register(sample_project("alpha"))
      assert :ok = ProjectRegistry.unregister("alpha")
      assert {:error, {:unknown_project, "alpha"}} = ProjectRegistry.lookup("alpha")
    end

    test "unregister/1 errors on an unknown name" do
      assert {:error, {:unknown_project, "missing"}} = ProjectRegistry.unregister("missing")
    end

    test "register/1 accepts attrs (keyword) and builds a validated, path-expanded project" do
      assert :ok =
               ProjectRegistry.register(
                 name: "kw",
                 source: {:local, "/tmp/kw"},
                 roadmap_path: "/tmp/kw",
                 check_command: "mix test",
                 reviewer: :codex,
                 warm_paths: ["priv/foo"]
               )

      assert {:ok, project} = ProjectRegistry.lookup("kw")
      assert project.name == "kw"
      assert project.source == {:local, "/tmp/kw"}
      assert project.check_command == "mix test"
      assert project.reviewer == :codex
      assert project.warm_paths == ["priv/foo"]
      # build_project defaults landing_policy when attrs omit it.
      assert project.landing_policy == :manual
    end

    test "register/1 returns invalid_project for attrs missing a required field" do
      assert {:error, {:invalid_project, {:missing, :roadmap_path}}} =
               ProjectRegistry.register(name: "bad", source: {:local, "/tmp/bad"})
    end
  end

  describe "Dispatch.register_project/6 — JSON-native registration" do
    test "registers a local-source project and makes it lookup-resolvable" do
      assert {:ok, %{name: "reg-local"}} =
               Dispatch.register_project("reg-local", "local", "/tmp/reg-local", "/tmp/reg-local", "mix test", 2)

      assert {:ok, project} = ProjectRegistry.lookup("reg-local")
      assert project.source == {:local, "/tmp/reg-local"}
      assert project.check_command == "mix test"
      assert project.concurrency_cap == 2
    end

    test "registers a github-source project with default optional fields" do
      assert {:ok, %{name: "reg-gh"}} =
               Dispatch.register_project("reg-gh", "github", "https://example.com/reg-gh.git", "/tmp/reg-gh")

      assert {:ok, project} = ProjectRegistry.lookup("reg-gh")
      assert project.source == {:github, "https://example.com/reg-gh.git"}
      assert project.check_command == nil
      assert project.concurrency_cap == nil
    end

    test "surfaces a duplicate registration as an error" do
      assert {:ok, _} = Dispatch.register_project("dup", "local", "/tmp/dup", "/tmp/dup")

      assert {:error, {:duplicate, "dup"}} =
               Dispatch.register_project("dup", "local", "/tmp/dup", "/tmp/dup")
    end

    test "rejects an unknown source_type before touching the registry" do
      assert {:error, {:invalid_source_type, "svn"}} =
               Dispatch.register_project("reg-bad", "svn", "/tmp/reg-bad", "/tmp/reg-bad")

      assert {:error, {:unknown_project, "reg-bad"}} = ProjectRegistry.lookup("reg-bad")
    end

    test "lookup/1 errors on an unknown name" do
      assert {:error, {:unknown_project, "missing"}} = ProjectRegistry.lookup("missing")
    end

    test "accepts a {:github, url} source" do
      project = %Harness.Project{
        name: "gh",
        source: {:github, "https://github.com/example/demo.git"},
        roadmap_path: "/tmp/gh"
      }

      assert :ok = ProjectRegistry.register(project)
      assert {:ok, ^project} = ProjectRegistry.lookup("gh")
    end
  end

  describe "repo_enabled false — memory-only runtime registration" do
    test "register/1 does not survive a registry restart when persistence is disabled" do
      name = "volatile-#{System.unique_integer([:positive])}"
      project = sample_project(name)

      assert :ok = ProjectRegistry.register(project)
      assert {:ok, ^project} = ProjectRegistry.lookup(name)

      assert :ok = ProjectRegistry.reset()
      assert {:ok, %{projects: %{}}} = ProjectRegistry.init(:noargs)

      assert {:error, {:unknown_project, ^name}} = ProjectRegistry.lookup(name)
    end

    test "upsert/1 inserts and replaces projects in memory when persistence is disabled" do
      name = "volatile-upsert-#{System.unique_integer([:positive])}"
      original = sample_project(name)
      replacement = %{original | check_command: "mix precommit", concurrency_cap: 2}

      assert :ok = ProjectRegistry.upsert(original)
      assert {:ok, ^original} = ProjectRegistry.lookup(name)

      assert :ok = ProjectRegistry.upsert(replacement)
      assert {:ok, ^replacement} = ProjectRegistry.lookup(name)
      assert [^replacement] = ProjectRegistry.list()
    end

    test "reload_persisted_state/0 reloads config projects when persistence is disabled" do
      name = "volatile-reload-#{System.unique_integer([:positive])}"
      prior = Application.get_env(:harness, :projects)

      on_exit(fn -> restore_projects_env(prior) end)

      Application.put_env(:harness, :projects, [
        [
          name: name,
          source: {:local, "/tmp/#{name}"},
          roadmap_path: "/tmp/#{name}/roadmap/tasks.toml",
          concurrency_cap: 5
        ]
      ])

      assert :ok = ProjectRegistry.reload_persisted_state()
      assert {:ok, project} = ProjectRegistry.lookup(name)
      assert project.concurrency_cap == 5
    end
  end

  describe "upsert/1 with persisted projects and live queues" do
    setup do
      start_supervised!(Repo)
      Sandbox.checkout(Repo)
      Sandbox.mode(Repo, {:shared, self()})

      prev_repo_enabled = Application.get_env(:harness, :repo_enabled)
      prev_projects = Application.get_env(:harness, :projects)
      prev_oban = Application.get_env(:harness, Oban)

      Application.put_env(:harness, :repo_enabled, true)
      Application.put_env(:harness, :projects, [])

      Application.put_env(:harness, Oban,
        name: HarnessOban,
        repo: Repo,
        notifier: Oban.Notifiers.Isolated,
        stage_interval: :infinity,
        queues: [],
        plugins: false
      )

      start_supervised!({Oban, Application.get_env(:harness, Oban)})

      on_exit(fn ->
        Application.put_env(:harness, :repo_enabled, prev_repo_enabled)
        restore_projects_env(prev_projects)
        Application.put_env(:harness, Oban, prev_oban)
      end)

      Repo.delete_all(ProjectSchema)
      ProjectRegistry.reset()

      :ok
    end

    @tag :integration
    test "replaces an existing project in memory and Postgres and scales its queue" do
      name = "upsert-existing-#{System.unique_integer([:positive])}"
      original = ProjectFixture.from_repo("/tmp/#{name}", name: name, concurrency_cap: 1)
      replacement = %{original | concurrency_cap: 4, check_command: "mix precommit"}

      assert :ok = ProjectRegistry.register(original)
      assert_queue_limit(name, 1)

      assert :ok = ProjectRegistry.upsert(replacement)

      assert {:ok, ^replacement} = ProjectRegistry.lookup(name)
      assert [^replacement] = ProjectRegistry.list()
      assert_persisted_project(replacement)
      assert_queue_limit(name, 4)
    end

    @tag :integration
    test "inserts a brand-new attrs project, persists it, and starts its queues" do
      name = "upsert-new-#{System.unique_integer([:positive])}"

      assert :ok =
               ProjectRegistry.upsert(
                 name: name,
                 source: {:local, "/tmp/#{name}"},
                 roadmap_path: "/tmp/#{name}/roadmap/tasks.toml",
                 concurrency_cap: 3
               )

      assert {:ok, project} = ProjectRegistry.lookup(name)
      assert project.name == name
      assert project.concurrency_cap == 3
      assert ProjectRegistry.list() == [project]
      assert_persisted_project(project)

      assert_queue_limit(name, 3)
      assert_queue_exists(HarnessOban.landing_queue_name(name))
    end

    @tag :integration
    test "re-upserting identical attrs is idempotent" do
      name = "upsert-idempotent-#{System.unique_integer([:positive])}"
      project = ProjectFixture.from_repo("/tmp/#{name}", name: name, concurrency_cap: 2)

      assert :ok = ProjectRegistry.upsert(project)
      assert_persisted_project(project)
      assert_queue_limit(name, 2)

      case ProjectRegistry.upsert(project) do
        :ok -> :ok
        {:error, reason} -> flunk("Unexpected upsert error: #{inspect(reason)}")
      end

      assert {:ok, ^project} = ProjectRegistry.lookup(name)
      assert_persisted_project(project)
      assert_queue_limit(name, 2)
    end
  end

  describe "init/1 — config-driven project loading" do
    # init/1 is called by the supervisor at boot. Exercising it directly
    # against a temporary :projects config covers build_project/1 and its
    # fetch_* helpers without touching the running registry — restarting
    # a supervised GenServer mid-suite races with subsequent setups.

    setup do
      prior = Application.get_env(:harness, :projects)

      on_exit(fn ->
        case prior do
          nil -> Application.delete_env(:harness, :projects)
          value -> Application.put_env(:harness, :projects, value)
        end
      end)
    end

    test "loads a valid project from keyword-list config" do
      entry = [
        name: "configured",
        source: {:local, "/tmp/harness-configured"},
        check_command: "mix precommit",
        roadmap_path: "/tmp/harness-configured/roadmap/tasks.toml",
        reviewer: :codex
      ]

      Application.put_env(:harness, :projects, [entry])

      assert {:ok, %{projects: %{"configured" => %Harness.Project{name: "configured"} = project}}} =
               ProjectRegistry.init(:noargs)

      assert project.check_command == "mix precommit"
      assert project.reviewer == :codex
    end

    test "loads a valid project from a map config" do
      entry = %{
        name: "configured-map",
        source: {:local, "/tmp/harness-cm"},
        check_command: "cargo test",
        roadmap_path: "/tmp/harness-cm/roadmap/tasks.toml",
        landing_policy: :auto,
        target_branch: "development"
      }

      Application.put_env(:harness, :projects, [entry])

      assert {:ok,
              %{
                projects: %{
                  "configured-map" => %Harness.Project{
                    check_command: "cargo test",
                    landing_policy: :auto,
                    target_branch: "development"
                  }
                }
              }} =
               ProjectRegistry.init(:noargs)
    end

    test "check_command is optional — the reviewer discovers the checks itself" do
      entry = [
        name: "no-hint",
        source: {:local, "/tmp/harness-no-hint"},
        roadmap_path: "/tmp/harness-no-hint/roadmap/tasks.toml"
      ]

      Application.put_env(:harness, :projects, [entry])

      assert {:ok, %{projects: %{"no-hint" => %Harness.Project{check_command: nil}}}} =
               ProjectRegistry.init(:noargs)
    end

    test "warm_paths is optional and defaults to an empty list" do
      entry = [
        name: "no-warm-paths",
        source: {:local, "/tmp/harness-no-warm-paths"},
        roadmap_path: "/tmp/harness-no-warm-paths/roadmap/tasks.toml"
      ]

      Application.put_env(:harness, :projects, [entry])

      assert {:ok, %{projects: %{"no-warm-paths" => %Harness.Project{warm_paths: []}}}} =
               ProjectRegistry.init(:noargs)
    end

    test "rejects a non-binary check_command" do
      bad = [
        name: "bad-check-command",
        source: {:local, "/tmp/x"},
        check_command: [:not, :a, :string],
        roadmap_path: "/tmp/x/tasks.toml"
      ]

      Application.put_env(:harness, :projects, [bad])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{projects: %{}}} = ProjectRegistry.init(:noargs)
        end)

      assert log =~ "skipping invalid config entry"
    end

    test "skips an invalid entry (missing :name) and logs a warning" do
      invalid = [source: {:local, "/tmp/x"}, roadmap_path: "/tmp/x/tasks.toml"]
      Application.put_env(:harness, :projects, [invalid])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{projects: %{}}} = ProjectRegistry.init(:noargs)
        end)

      assert log =~ "skipping invalid config entry"
    end

    test "rejects a non-binary roadmap_path" do
      bad = [
        name: "bad-roadmap",
        source: {:local, "/tmp/x"},
        roadmap_path: :not_a_path
      ]

      Application.put_env(:harness, :projects, [bad])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{projects: %{}}} = ProjectRegistry.init(:noargs)
        end)

      assert log =~ "skipping invalid config entry"
    end

    test "rejects an unsupported source shape" do
      bad = [
        name: "bad-source",
        source: {:remote, "https://example.com/repo"},
        roadmap_path: "/tmp/x/tasks.toml"
      ]

      Application.put_env(:harness, :projects, [bad])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{projects: %{}}} = ProjectRegistry.init(:noargs)
        end)

      assert log =~ "skipping invalid config entry"
    end

    test "warns when repo-enabled boot sees config projects" do
      prior_repo_enabled = Application.get_env(:harness, :repo_enabled)

      on_exit(fn -> Application.put_env(:harness, :repo_enabled, prior_repo_enabled) end)

      Application.put_env(:harness, :repo_enabled, true)

      Application.put_env(:harness, :projects, [
        [
          name: "shadowed-config",
          source: {:local, "/tmp/shadowed-config"},
          roadmap_path: "/tmp/shadowed-config/roadmap/tasks.toml"
        ]
      ])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _state} = ProjectRegistry.init(:noargs)
        end)

      assert log =~ "config projects are seed-only"
      assert log =~ "/harness/settings"
      assert log =~ "mix harness.seed"
    end

    test "does not warn when repo-enabled boot has no config projects" do
      prior_repo_enabled = Application.get_env(:harness, :repo_enabled)

      on_exit(fn -> Application.put_env(:harness, :repo_enabled, prior_repo_enabled) end)

      Application.put_env(:harness, :repo_enabled, true)
      Application.put_env(:harness, :projects, [])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _state} = ProjectRegistry.init(:noargs)
        end)

      refute log =~ "config projects are seed-only"
    end
  end

  describe "configuration guards" do
    test "config/dev.exs no longer declares project registrations" do
      config = File.read!("config/dev.exs")

      refute config =~ ~r/config\s+:harness,\s+:projects/
      refute config =~ "dev.local.exs"
    end
  end

  describe "concurrent runs across registered projects" do
    test "two registered projects settle independently on their reviewers' verdicts" do
      base = GitFixture.tmp_base()
      repo_a = GitFixture.init_repo(name: "proj-a")
      repo_b = GitFixture.init_repo(name: "proj-b")

      project_a = ProjectFixture.from_repo(repo_a, name: "proj-a")
      project_b = ProjectFixture.from_repo(repo_b, name: "proj-b")

      assert :ok = ProjectRegistry.register(project_a)
      assert :ok = ProjectRegistry.register(project_b)

      item = fn id ->
        %Item{id: id, title: "Task #{id}", prompt: "do it", agent: :claude}
      end

      opts = fn verdict ->
        [
          base_dir: base,
          adapter_opts: [command: :write],
          reviewer: Harness.FakeAdapter,
          reviewer_adapter_opts: [command: {:review, verdict}],
          total_timeout: 30_000,
          idle_timeout: 10_000,
          lifetime_timeout: 30_000,
          terminal_linger: 100
        ]
      end

      tasks =
        Enum.map(
          [
            {project_a, "a", "approve"},
            {project_b, "b", "reject"}
          ],
          fn {project, id, verdict} ->
            Task.async(fn ->
              {:ok, run_id, pid} =
                RunSupervisor.start_run(item.(id), project, Harness.FakeAdapter, opts.(verdict))

              await_result(run_id, pid)
            end)
          end
        )

      [result_a, result_b] = Enum.map(tasks, &Task.await(&1, 15_000))

      assert %Result{task_id: "a", state: :done, reason: :approved} = result_a
      assert %Result{task_id: "b", state: :failed, reason: {:review_rejected, _report}} = result_b
    end
  end

  describe "lookup/1 + list/0 return the landing-overlaid effective project (Task 257)" do
    setup do
      SettingsStoreMemory.reset(scope: :test_default)
      on_exit(fn -> SettingsStoreMemory.reset(scope: :test_default) end)
      :ok
    end

    test "lookup overlays a persisted :auto/branch override onto a :manual/nil registration default" do
      project = %{sample_project("flip") | landing_policy: :manual, target_branch: nil}
      assert :ok = ProjectRegistry.register(project)
      assert :ok = LandingSettings.set("flip", :auto, "release", "test")

      assert {:ok, effective} = ProjectRegistry.lookup("flip")
      assert effective.landing_policy == :auto
      assert effective.target_branch == "release"
    end

    test "list reflects the same overlay" do
      project = %{sample_project("flip") | landing_policy: :manual, target_branch: nil}
      assert :ok = ProjectRegistry.register(project)
      assert :ok = LandingSettings.set("flip", :auto, "release", "test")

      assert [effective] = ProjectRegistry.list()
      assert effective.landing_policy == :auto
      assert effective.target_branch == "release"
    end

    test "a reviewer override is overlaid too" do
      project = sample_project("rev")
      assert :ok = ProjectRegistry.register(project)
      assert :ok = LandingSettings.set_reviewer("rev", :codex, "test")

      assert {:ok, %{reviewer: :codex}} = ProjectRegistry.lookup("rev")
    end

    test "no override: the registration default stands unchanged (lookup and list)" do
      project = %{sample_project("plain") | landing_policy: :manual, target_branch: nil}
      assert :ok = ProjectRegistry.register(project)

      assert {:ok, ^project} = ProjectRegistry.lookup("plain")
      assert [^project] = ProjectRegistry.list()
    end

    test "overlay/1 is applied at exactly ONE read boundary — no stray per-call-site overlay" do
      # The single-source guard: the only places that call Landing.Settings.overlay/1
      # are the ProjectRegistry read boundary and Landing.Settings itself
      # (effective/1). A re-introduced per-call-site overlay (the Task 171 trap)
      # fails this immediately.
      boundary = ["lib/harness/project_registry.ex", "lib/harness/landing/settings.ex"]

      offenders =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.reject(&(&1 in boundary))
        |> Enum.filter(&(File.read!(&1) =~ ~r/\.overlay\(/))

      assert offenders == [],
             "overlay/1 must be applied only at the ProjectRegistry read boundary; stray call sites: #{inspect(offenders)}"
    end
  end

  defp sample_project(name) do
    ProjectFixture.from_repo("/tmp/#{name}", name: name)
  end

  defp restore_projects_env(nil), do: Application.delete_env(:harness, :projects)
  defp restore_projects_env(projects), do: Application.put_env(:harness, :projects, projects)

  defp assert_persisted_project(project) do
    assert %ProjectSchema{payload: payload} = Repo.get(ProjectSchema, project.name)
    assert ^project = :erlang.binary_to_term(payload)
  end

  defp assert_queue_limit(project_name, expected_limit) do
    assert_eventually(fn ->
      assert %{limit: ^expected_limit} =
               Oban.check_queue(HarnessOban, queue: HarnessOban.queue_name(project_name))
    end)
  end

  defp assert_queue_exists(queue_name) do
    assert_eventually(fn ->
      assert %{queue: ^queue_name} = Oban.check_queue(HarnessOban, queue: queue_name)
    end)
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

  defp await_result(run_id, pid, timeout \\ 10_000) do
    ref = Process.monitor(pid)
    assert_receive {:harness_run, ^run_id, %Result{} = result}, timeout
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, timeout
    result
  end
end
