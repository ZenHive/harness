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
  end

  describe "concurrent runs per project check stack" do
    test "two registered projects grade with their own check stacks" do
      base = GitFixture.tmp_base()
      repo_a = GitFixture.init_repo(name: "proj-a")
      repo_b = GitFixture.init_repo(name: "proj-b")

      pass_stack = %CheckStack{name: :pass, checks: [check("ok", "true")]}
      fail_stack = %CheckStack{name: :fail, checks: [check("no", "false")]}

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
              {:ok, run_id, pid} = RunSupervisor.start_run(item.(id), project, Harness.FakeAdapter, opts)
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
