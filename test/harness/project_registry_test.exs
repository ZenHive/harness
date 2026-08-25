defmodule Harness.ProjectRegistryTest.CountingSettingsStore do
  @moduledoc false
  @behaviour Harness.SettingsStore

  alias Harness.Test.SettingsStoreMemory

  @impl Harness.SettingsStore
  @spec fetch(String.t(), keyword()) :: {:ok, term()} | :not_found
  def fetch(key, backend_opts) when is_binary(key) and is_list(backend_opts) do
    owner = Keyword.get(backend_opts, :owner)

    if key == "landing" and owner do
      send(owner, :landing_fetch)
    end

    # Delegate storage to the memory impl (same scope key) so data is shared
    # regardless of which backend name is configured for the test.
    SettingsStoreMemory.fetch(key, Keyword.delete(backend_opts, :owner))
  end

  @impl Harness.SettingsStore
  @spec put(String.t(), term(), keyword()) :: :ok
  def put(key, value, backend_opts) when is_binary(key) and is_list(backend_opts) do
    SettingsStoreMemory.put(key, value, Keyword.delete(backend_opts, :owner))
  end
end

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
  alias Harness.Test.IdentityFakeAdapter, as: FakeAdapter
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
                 languages: [:typescript],
                 reviewer: :codex,
                 warm_paths: ["priv/foo"]
               )

      assert {:ok, project} = ProjectRegistry.lookup("kw")
      assert project.name == "kw"
      assert project.source == {:local, "/tmp/kw"}
      assert project.check_command == "mix test"
      assert project.languages == [:typescript]
      assert project.reviewer == :codex
      assert project.warm_paths == ["priv/foo"]
      # build_project defaults landing_policy when attrs omit it.
      assert project.landing_policy == :manual
    end

    test "register/1 returns invalid_project for attrs missing a required field" do
      assert {:error, {:invalid_project, {:missing, :roadmap_path}}} =
               ProjectRegistry.register(name: "bad", source: {:local, "/tmp/bad"})
    end

    test "register/1 rejects attrs without explicit non-empty languages" do
      attrs = [name: "bad-languages", source: {:local, "/tmp/bad"}, roadmap_path: "/tmp/bad"]

      assert {:error, {:invalid_project, {:missing, :languages}}} = ProjectRegistry.register(attrs)

      assert {:error, {:invalid_project, {:empty, :languages}}} =
               ProjectRegistry.register(Keyword.put(attrs, :languages, []))

      assert {:error, {:invalid_project, {:invalid_languages, :mixed}}} =
               ProjectRegistry.register(Keyword.put(attrs, :languages, [:mixed]))
    end
  end

  describe "Dispatch.register_project/9 — JSON-native registration" do
    test "registers a local-source project and makes it lookup-resolvable" do
      assert {:ok, %{name: "reg-local"}} =
               Dispatch.register_project(
                 "reg-local",
                 "local",
                 "/tmp/reg-local",
                 "/tmp/reg-local",
                 [:typescript],
                 "mix test",
                 2
               )

      assert {:ok, project} = ProjectRegistry.lookup("reg-local")
      assert project.source == {:local, "/tmp/reg-local"}
      assert project.check_command == "mix test"
      assert project.concurrency_cap == 2
      assert project.languages == [:typescript]
      assert project.warm_paths == []
      assert project.roadmap_target_branch == nil
    end

    test "registers warm_paths through the optional JSON-native argument" do
      assert {:ok, %{name: "reg-warm"}} =
               Dispatch.register_project(
                 "reg-warm",
                 "local",
                 "/tmp/reg-warm",
                 "/tmp/reg-warm",
                 [:elixir],
                 nil,
                 nil,
                 ["priv/discoveries", "source"]
               )

      assert {:ok, project} = ProjectRegistry.lookup("reg-warm")
      assert project.warm_paths == ["priv/discoveries", "source"]
    end

    test "registers roadmap_target_branch through the optional JSON-native argument" do
      assert {:ok, %{name: "reg-roadmap-branch"}} =
               Dispatch.register_project(
                 "reg-roadmap-branch",
                 "local",
                 "/tmp/reg-roadmap-branch",
                 "/tmp/reg-roadmap-branch",
                 [:elixir],
                 nil,
                 nil,
                 [],
                 "roadmap-main"
               )

      assert {:ok, project} = ProjectRegistry.lookup("reg-roadmap-branch")
      assert project.roadmap_target_branch == "roadmap-main"
    end

    test "omitting roadmap_target_branch leaves it nil so same-repo writes derive from target_branch" do
      assert {:ok, %{name: "reg-omit-roadmap-branch"}} =
               Dispatch.register_project(
                 "reg-omit-roadmap-branch",
                 "local",
                 "/tmp/reg-omit-roadmap-branch",
                 "/tmp/reg-omit-roadmap-branch",
                 [:elixir]
               )

      assert {:ok, project} = ProjectRegistry.lookup("reg-omit-roadmap-branch")
      assert project.roadmap_target_branch == nil
    end

    test "blank roadmap_target_branch is stored as nil" do
      assert {:ok, %{name: "reg-blank-roadmap-branch"}} =
               Dispatch.register_project(
                 "reg-blank-roadmap-branch",
                 "local",
                 "/tmp/reg-blank-roadmap-branch",
                 "/tmp/reg-blank-roadmap-branch",
                 [:elixir],
                 nil,
                 nil,
                 [],
                 "  "
               )

      assert {:ok, project} = ProjectRegistry.lookup("reg-blank-roadmap-branch")
      assert project.roadmap_target_branch == nil
    end

    test "rejects an invalid roadmap_target_branch" do
      assert {:error, {:invalid_project, {:invalid_roadmap_target_branch, "bad branch"}}} =
               Dispatch.register_project(
                 "reg-bad-roadmap-branch",
                 "local",
                 "/tmp/reg-bad-roadmap-branch",
                 "/tmp/reg-bad-roadmap-branch",
                 [:elixir],
                 nil,
                 nil,
                 [],
                 "bad branch"
               )

      assert {:error, {:unknown_project, "reg-bad-roadmap-branch"}} =
               ProjectRegistry.lookup("reg-bad-roadmap-branch")
    end

    test "registers a github-source project with default optional fields" do
      assert {:ok, %{name: "reg-gh"}} =
               Dispatch.register_project("reg-gh", "github", "https://example.com/reg-gh.git", "/tmp/reg-gh", [:elixir])

      assert {:ok, project} = ProjectRegistry.lookup("reg-gh")
      assert project.source == {:github, "https://example.com/reg-gh.git"}
      assert project.check_command == nil
      assert project.concurrency_cap == nil
      assert project.languages == [:elixir]
      assert project.warm_paths == []
    end

    test "normalizes JSON string languages to atoms" do
      assert {:ok, %{name: "reg-json-lang"}} =
               Dispatch.register_project("reg-json-lang", "local", "/tmp/reg-json-lang", "/tmp/reg-json-lang", [
                 "elixir",
                 "rust"
               ])

      assert {:ok, project} = ProjectRegistry.lookup("reg-json-lang")
      assert project.languages == [:elixir, :rust]
    end

    test "surfaces a duplicate registration as an error" do
      assert {:ok, _} = Dispatch.register_project("dup", "local", "/tmp/dup", "/tmp/dup", [:elixir])

      assert {:error, {:duplicate, "dup"}} =
               Dispatch.register_project("dup", "local", "/tmp/dup", "/tmp/dup", [:elixir])
    end

    test "rejects an unknown source_type before touching the registry" do
      assert {:error, {:invalid_source_type, "svn"}} =
               Dispatch.register_project("reg-bad", "svn", "/tmp/reg-bad", "/tmp/reg-bad", [:elixir])

      assert {:error, {:unknown_project, "reg-bad"}} = ProjectRegistry.lookup("reg-bad")
    end

    test "lookup/1 errors on an unknown name" do
      assert {:error, {:unknown_project, "missing"}} = ProjectRegistry.lookup("missing")
    end

    test "accepts a {:github, url} source" do
      project = %Harness.Project{
        name: "gh",
        source: {:github, "https://github.com/example/demo.git"},
        roadmap_path: "/tmp/gh",
        languages: [:elixir]
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
          languages: [:elixir],
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
                 languages: [:elixir],
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
    test "dispatch registration persists warm_paths and reloads them from Postgres" do
      name = "dispatch-warm-#{System.unique_integer([:positive])}"
      warm_paths = ["priv/discoveries", "source"]

      assert {:ok, %{name: ^name}} =
               Dispatch.register_project(
                 name,
                 "local",
                 "/tmp/#{name}",
                 "/tmp/#{name}/roadmap/tasks.toml",
                 [:elixir],
                 nil,
                 nil,
                 warm_paths
               )

      assert {:ok, project} = ProjectRegistry.lookup(name)
      assert project.warm_paths == warm_paths
      assert %ProjectSchema{warm_paths: ^warm_paths} = Repo.get(ProjectSchema, name)

      assert :ok = ProjectRegistry.reset()
      assert :ok = ProjectRegistry.reload_persisted_state()
      assert {:ok, restored} = ProjectRegistry.lookup(name)
      assert restored.warm_paths == warm_paths
    end

    @tag :integration
    test "dispatch registration persists roadmap_target_branch and reloads it from Postgres" do
      name = "dispatch-roadmap-branch-#{System.unique_integer([:positive])}"

      assert {:ok, %{name: ^name}} =
               Dispatch.register_project(
                 name,
                 "local",
                 "/tmp/#{name}",
                 "/tmp/#{name}/roadmap/tasks.toml",
                 [:elixir],
                 nil,
                 nil,
                 [],
                 "roadmap-main"
               )

      assert {:ok, project} = ProjectRegistry.lookup(name)
      assert project.roadmap_target_branch == "roadmap-main"

      assert :ok = ProjectRegistry.reset()
      assert :ok = ProjectRegistry.reload_persisted_state()
      assert {:ok, restored} = ProjectRegistry.lookup(name)
      assert restored.roadmap_target_branch == "roadmap-main"
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

    @tag :integration
    test "reload backfills legacy singular language payloads and re-persists them" do
      nil_name = "legacy-language-nil-#{System.unique_integer([:positive])}"
      rust_name = "legacy-language-rust-#{System.unique_integer([:positive])}"

      insert_legacy_project!(nil_name, nil)
      insert_legacy_project!(rust_name, :rust)

      assert :ok = ProjectRegistry.reload_persisted_state()
      assert_backfilled_languages(nil_name, [:elixir])
      assert_backfilled_languages(rust_name, [:rust])
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
        languages: [:elixir],
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
        languages: [:rust],
        landing_policy: :auto,
        roadmap_target_branch: "roadmap-main",
        target_branch: "development"
      }

      Application.put_env(:harness, :projects, [entry])

      assert {:ok,
              %{
                projects: %{
                  "configured-map" => %Harness.Project{
                    check_command: "cargo test",
                    landing_policy: :auto,
                    roadmap_target_branch: "roadmap-main",
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
        roadmap_path: "/tmp/harness-no-hint/roadmap/tasks.toml",
        languages: [:elixir]
      ]

      Application.put_env(:harness, :projects, [entry])

      assert {:ok, %{projects: %{"no-hint" => %Harness.Project{check_command: nil}}}} =
               ProjectRegistry.init(:noargs)
    end

    test "warm_paths is optional and defaults to an empty list" do
      entry = [
        name: "no-warm-paths",
        source: {:local, "/tmp/harness-no-warm-paths"},
        roadmap_path: "/tmp/harness-no-warm-paths/roadmap/tasks.toml",
        languages: [:elixir]
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
        languages: [:elixir],
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
      invalid = [source: {:local, "/tmp/x"}, roadmap_path: "/tmp/x/tasks.toml", languages: [:elixir]]
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
        languages: [:elixir],
        roadmap_path: :not_a_path
      ]

      Application.put_env(:harness, :projects, [bad])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{projects: %{}}} = ProjectRegistry.init(:noargs)
        end)

      assert log =~ "skipping invalid config entry"
    end

    test "rejects an invalid roadmap_target_branch" do
      bad = [
        name: "bad-roadmap-target",
        source: {:local, "/tmp/x"},
        languages: [:elixir],
        roadmap_path: "/tmp/x",
        roadmap_target_branch: "bad branch"
      ]

      Application.put_env(:harness, :projects, [bad])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{projects: %{}}} = ProjectRegistry.init(:noargs)
        end)

      assert log =~ "invalid_roadmap_target_branch"
    end

    test "rejects an unsupported source shape" do
      bad = [
        name: "bad-source",
        source: {:remote, "https://example.com/repo"},
        languages: [:elixir],
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
          roadmap_path: "/tmp/shadowed-config/roadmap/tasks.toml",
          languages: [:elixir]
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
          reviewer: FakeAdapter,
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
                RunSupervisor.start_run(item.(id), project, FakeAdapter, opts.(verdict))

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

    test "list/0 issues exactly one landing-settings fetch regardless of project count" do
      owner = self()
      scope = :"one_fetch_#{System.unique_integer([:positive])}"
      SettingsStoreMemory.reset(scope: scope)

      # Seed data using the memory backend (no owner -> no count messages).
      prev = Application.get_env(:harness, :settings_store)
      Application.put_env(:harness, :settings_store, {SettingsStoreMemory, scope: scope})

      on_exit(fn ->
        SettingsStoreMemory.reset(scope: scope)
        Application.put_env(:harness, :settings_store, prev)
      end)

      p1 = %{sample_project("batch1") | landing_policy: :manual, target_branch: nil}
      p2 = %{sample_project("batch2") | landing_policy: :manual, target_branch: nil}
      assert :ok = ProjectRegistry.register(p1)
      assert :ok = ProjectRegistry.register(p2)
      assert :ok = LandingSettings.set("batch1", :auto, "main", "test")

      # Now swap to counting backend (shares ETS data via scope).
      counting = {Harness.ProjectRegistryTest.CountingSettingsStore, scope: scope, owner: owner}
      Application.put_env(:harness, :settings_store, counting)

      flush_messages()

      assert [e1, e2] = ProjectRegistry.list()
      assert e1.landing_policy == :auto
      assert e1.target_branch == "main"
      assert e2.landing_policy == :manual

      fetches = drain_landing_fetches()

      assert fetches == 1,
             "ProjectRegistry.list/0 with #{length([e1, e2])} projects must issue exactly 1 landing fetch, got #{fetches}"
    end
  end

  defp sample_project(name) do
    ProjectFixture.from_repo("/tmp/#{name}", name: name)
  end

  defp flush_messages do
    receive do
      _ -> flush_messages()
    after
      0 -> :ok
    end
  end

  defp drain_landing_fetches(acc \\ 0) do
    receive do
      :landing_fetch -> drain_landing_fetches(acc + 1)
    after
      0 -> acc
    end
  end

  @spec insert_legacy_project!(String.t(), atom() | nil) :: :ok
  defp insert_legacy_project!(name, language) do
    legacy = %{
      __struct__: Harness.Project,
      name: name,
      source: {:local, "/tmp/#{name}"},
      roadmap_path: "/tmp/#{name}/roadmap/tasks.toml",
      check_command: nil,
      language: language,
      concurrency_cap: nil,
      pollution_allowlist: nil,
      warm_paths: [],
      landing_policy: :manual,
      target_branch: nil,
      reviewer: nil,
      test_db_isolation_env: nil,
      tooling_baseline_overrides: %{}
    }

    attrs = %{name: name, payload: :erlang.term_to_binary(legacy), warm_paths: []}
    assert {:ok, _row} = Repo.insert(ProjectSchema.changeset(%ProjectSchema{name: name}, attrs))
    :ok
  end

  @spec assert_backfilled_languages(String.t(), nonempty_list(atom())) :: :ok
  defp assert_backfilled_languages(name, languages) do
    assert {:ok, project} = ProjectRegistry.lookup(name)
    assert project.languages == languages
    refute Map.has_key?(Map.from_struct(project), :language)

    %ProjectSchema{payload: payload} = Repo.get(ProjectSchema, name)
    persisted = :erlang.binary_to_term(payload)
    assert persisted.languages == languages
    refute Map.has_key?(Map.from_struct(persisted), :language)
    :ok
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
