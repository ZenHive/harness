defmodule Harness.ProjectRegistryTest do
  use ExUnit.Case, async: false

  alias Harness.CheckStack
  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.Roadmap.Item
  alias Harness.Run.Result
  alias Harness.Run.Supervisor, as: RunSupervisor
  alias Harness.Verification.Check

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

    test "lookup/1 errors on an unknown name" do
      assert {:error, {:unknown_project, "missing"}} = ProjectRegistry.lookup("missing")
    end

    test "accepts a {:github, url} source" do
      project = %Harness.Project{
        name: "gh",
        source: {:github, "https://github.com/example/demo.git"},
        check_stacks: [%CheckStack{name: :tiny, checks: []}],
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
        preset: :elixir,
        roadmap_path: "/tmp/harness-configured/roadmap/tasks.toml"
      ]

      Application.put_env(:harness, :projects, [entry])

      assert {:ok, %{projects: %{"configured" => %Harness.Project{name: "configured"}}}} =
               ProjectRegistry.init(:noargs)
    end

    test "loads a valid project from a map config" do
      entry = %{
        name: "configured-map",
        source: {:local, "/tmp/harness-cm"},
        check_stack: %CheckStack{name: :smoke, checks: []},
        roadmap_path: "/tmp/harness-cm/roadmap/tasks.toml",
        landing_policy: :auto
      }

      Application.put_env(:harness, :projects, [entry])

      assert {:ok,
              %{
                projects: %{
                  "configured-map" => %Harness.Project{
                    check_stacks: [%CheckStack{name: :smoke}],
                    landing_policy: :auto
                  }
                }
              }} =
               ProjectRegistry.init(:noargs)
    end

    test "reads a project-level review_green boolean" do
      entry = [
        name: "unreviewed",
        source: {:local, "/tmp/harness-unreviewed"},
        preset: :elixir,
        roadmap_path: "/tmp/harness-unreviewed/roadmap/tasks.toml",
        review_green: false
      ]

      Application.put_env(:harness, :projects, [entry])

      assert {:ok, %{projects: %{"unreviewed" => %Harness.Project{review_green: false}}}} =
               ProjectRegistry.init(:noargs)
    end

    test "defaults review_green to true when unset" do
      entry = [
        name: "reviewed-by-default",
        source: {:local, "/tmp/harness-reviewed"},
        preset: :elixir,
        roadmap_path: "/tmp/harness-reviewed/roadmap/tasks.toml"
      ]

      Application.put_env(:harness, :projects, [entry])

      assert {:ok, %{projects: %{"reviewed-by-default" => %Harness.Project{review_green: true}}}} =
               ProjectRegistry.init(:noargs)
    end

    test "back-compat: legacy semantic_gate :always and :auto_land_only map to review_green: true" do
      for legacy <- [:always, :auto_land_only] do
        name = "legacy-#{legacy}"

        entry = [
          name: name,
          source: {:local, "/tmp/harness-legacy"},
          preset: :elixir,
          roadmap_path: "/tmp/harness-legacy/roadmap/tasks.toml",
          semantic_gate: legacy
        ]

        Application.put_env(:harness, :projects, [entry])

        assert {:ok, %{projects: %{^name => %Harness.Project{review_green: true}}}} =
                 ProjectRegistry.init(:noargs)
      end
    end

    test "back-compat: legacy semantic_gate :off maps to review_green: false" do
      entry = [
        name: "legacy-off",
        source: {:local, "/tmp/harness-legacy-off"},
        preset: :elixir,
        roadmap_path: "/tmp/harness-legacy-off/roadmap/tasks.toml",
        semantic_gate: :off
      ]

      Application.put_env(:harness, :projects, [entry])

      assert {:ok, %{projects: %{"legacy-off" => %Harness.Project{review_green: false}}}} =
               ProjectRegistry.init(:noargs)
    end

    test "rejects a non-boolean review_green" do
      bad = [
        name: "bad-review-green",
        source: {:local, "/tmp/x"},
        preset: :elixir,
        roadmap_path: "/tmp/x/tasks.toml",
        review_green: :always
      ]

      Application.put_env(:harness, :projects, [bad])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{projects: %{}}} = ProjectRegistry.init(:noargs)
        end)

      assert log =~ "skipping invalid config entry"
    end

    test "rejects an unknown legacy semantic_gate mode" do
      bad = [
        name: "bad-gate",
        source: {:local, "/tmp/x"},
        preset: :elixir,
        roadmap_path: "/tmp/x/tasks.toml",
        semantic_gate: :sometimes
      ]

      Application.put_env(:harness, :projects, [bad])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{projects: %{}}} = ProjectRegistry.init(:noargs)
        end)

      assert log =~ "skipping invalid config entry"
    end

    test "back-compat: a singular preset becomes a one-element stack at the repo root" do
      entry = [
        name: "single-preset",
        source: {:local, "/tmp/harness-single"},
        preset: :elixir,
        roadmap_path: "/tmp/harness-single/roadmap/tasks.toml"
      ]

      Application.put_env(:harness, :projects, [entry])

      assert {:ok, %{projects: %{"single-preset" => project}}} = ProjectRegistry.init(:noargs)
      assert [%CheckStack{name: :elixir, workdir: ""}] = project.check_stacks
    end

    test "a parameterized {:elixir_precommit, opts} preset declares the project's merge gate" do
      entry = [
        name: "merge-gated",
        source: {:local, "/tmp/harness-mg"},
        preset: {:elixir_precommit, cover_threshold: 85, exclude: [:integration]},
        roadmap_path: "/tmp/harness-mg/roadmap/tasks.toml"
      ]

      Application.put_env(:harness, :projects, [entry])

      assert {:ok, %{projects: %{"merge-gated" => project}}} = ProjectRegistry.init(:noargs)
      assert [%CheckStack{name: :elixir_precommit, workdir: ""} = stack] = project.check_stacks

      test_check = Enum.find(stack.checks, &(&1.name == "test"))
      assert "85" in test_check.args
      assert "integration" in test_check.args
    end

    test "a parameterized {:rust, opts} preset (target_dir/release/env/timeout) is durable via config" do
      entry = [
        name: "rexex",
        source: {:local, "/tmp/rexex"},
        preset:
          {:rust,
           target_dir: "/cache/harness/rexex",
           release: false,
           timeout_per_check: 1_800_000,
           env: %{"DATABASE_URL" => "postgres://localhost/rexex_test"}},
        roadmap_path: "/tmp/rexex/roadmap/tasks.toml"
      ]

      Application.put_env(:harness, :projects, [entry])

      assert {:ok, %{projects: %{"rexex" => project}}} = ProjectRegistry.init(:noargs)
      assert [%CheckStack{name: :rust, workdir: "", timeout_per_check: 1_800_000} = stack] = project.check_stacks

      testc = Enum.find(stack.checks, &(&1.name == "test"))
      assert "--target-dir" in testc.args
      assert "/cache/harness/rexex" in testc.args
      build = Enum.find(stack.checks, &(&1.name == "build"))
      refute "--release" in build.args
      assert testc.env == %{"DATABASE_URL" => "postgres://localhost/rexex_test"}
    end

    test "loads multiple stacks from a :stacks list, each with its own workdir" do
      entry = [
        name: "multi",
        source: {:local, "/tmp/harness-multi"},
        stacks: [
          [preset: :rust, workdir: "rust"],
          [check_stack: %CheckStack{name: :web, checks: []}, workdir: "elixir"]
        ],
        roadmap_path: "/tmp/harness-multi/roadmap/tasks.toml"
      ]

      Application.put_env(:harness, :projects, [entry])

      assert {:ok, %{projects: %{"multi" => project}}} = ProjectRegistry.init(:noargs)

      assert [
               %CheckStack{name: :rust, workdir: "rust"},
               %CheckStack{name: :web, workdir: "elixir"}
             ] = project.check_stacks
    end

    test "skips an invalid entry (missing :name) and logs a warning" do
      invalid = [source: {:local, "/tmp/x"}, preset: :elixir, roadmap_path: "/tmp/x/tasks.toml"]
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
        preset: :elixir,
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
        preset: :elixir,
        roadmap_path: "/tmp/x/tasks.toml"
      ]

      Application.put_env(:harness, :projects, [bad])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{projects: %{}}} = ProjectRegistry.init(:noargs)
        end)

      assert log =~ "skipping invalid config entry"
    end

    test "rejects an entry missing check_stack/preset" do
      bad = [
        name: "no-stack",
        source: {:local, "/tmp/x"},
        roadmap_path: "/tmp/x/tasks.toml"
      ]

      Application.put_env(:harness, :projects, [bad])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{projects: %{}}} = ProjectRegistry.init(:noargs)
        end)

      assert log =~ "skipping invalid config entry"
    end
  end

  describe "concurrent runs per project check stack" do
    test "two registered projects grade with their own check stacks" do
      base = GitFixture.tmp_base()
      repo_a = GitFixture.init_repo(name: "proj-a")
      repo_b = GitFixture.init_repo(name: "proj-b")

      pass_stack = %CheckStack{name: :pass, checks: [check("ok", "true")]}
      fail_stack = %CheckStack{name: :fail, checks: [check("no", "test", ["!", "-f", "agent_output.txt"])]}

      project_a = ProjectFixture.from_repo(repo_a, name: "proj-a", check_stack: pass_stack)
      project_b = ProjectFixture.from_repo(repo_b, name: "proj-b", check_stack: fail_stack)

      assert :ok = ProjectRegistry.register(project_a)
      assert :ok = ProjectRegistry.register(project_b)

      item = fn id ->
        %Item{id: id, title: "Task #{id}", prompt: "do it", agent: :claude}
      end

      opts = [
        base_dir: base,
        adapter_opts: [command: :write],
        total_timeout: 30_000,
        idle_timeout: 10_000,
        lifetime_timeout: 30_000,
        verification_timeout: 10_000,
        terminal_linger: 100,
        max_repair_attempts: 0
      ]

      tasks =
        Enum.map(
          [
            {project_a, "a"},
            {project_b, "b"}
          ],
          fn {project, id} ->
            Task.async(fn ->
              {:ok, run_id, pid} =
                RunSupervisor.start_run(item.(id), project, Harness.FakeAdapter, opts)

              await_result(run_id, pid)
            end)
          end
        )

      [result_a, result_b] = Enum.map(tasks, &Task.await(&1, 10_000))

      assert %Result{task_id: "a", state: :done, reason: :passed} = result_a
      assert %Result{task_id: "b", state: :failed, reason: :verification_red} = result_b
    end
  end

  defp sample_project(name) do
    ProjectFixture.from_repo("/tmp/#{name}", name: name)
  end

  defp check(name, command, args \\ []), do: %Check{name: name, command: command, args: args}

  defp await_result(run_id, pid, timeout \\ 5_000) do
    ref = Process.monitor(pid)
    assert_receive {:harness_run, ^run_id, %Result{} = result}, timeout
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, timeout
    result
  end
end
