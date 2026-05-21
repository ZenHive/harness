defmodule Harness.Run.SupervisorTest do
  use ExUnit.Case, async: true

  alias Harness.FakeAdapter
  alias Harness.GitFixture
  alias Harness.Roadmap.Item
  alias Harness.Run
  alias Harness.Run.Result
  alias Harness.Verification.Check

  test "child_spec marks runs :temporary so a failed run is never restarted" do
    arg = {item(), "/repo", FakeAdapter, [run_id: "x"]}
    assert %{restart: :temporary} = Run.child_spec(arg)
  end

  @tag :capture_log
  test "a crashing run is isolated from its siblings" do
    base = GitFixture.tmp_base()
    repo_a = GitFixture.init_repo(name: "repo-a")
    repo_b = GitFixture.init_repo(name: "repo-b")

    # Run A holds in :running on a sleeping agent until it is crashed.
    {:ok, _id_a, pid_a} =
      Run.Supervisor.start_run(item(), repo_a, FakeAdapter,
        base_dir: base,
        adapter_opts: [command: :sleep],
        idle_timeout: 2_000,
        total_timeout: 5_000,
        lifetime_timeout: 30_000,
        terminal_linger: 100
      )

    # Run B is an ordinary run that should complete unaffected.
    {:ok, id_b, _pid_b} =
      Run.Supervisor.start_run(item(), repo_b, FakeAdapter,
        base_dir: base,
        adapter_opts: [command: :write],
        checks: [check("ok", "true")],
        total_timeout: 30_000,
        idle_timeout: 10_000,
        lifetime_timeout: 30_000,
        terminal_linger: 100
      )

    Process.exit(pid_a, :kill)

    assert_receive {:harness_run, ^id_b, %Result{state: :done}}, 10_000
    refute Process.alive?(pid_a)
  end

  test "list_runs reports an active run id" do
    base = GitFixture.tmp_base()
    repo = GitFixture.init_repo()

    {:ok, run_id, pid} =
      Run.Supervisor.start_run(item(), repo, FakeAdapter,
        base_dir: base,
        adapter_opts: [command: :sleep],
        idle_timeout: 5_000,
        total_timeout: 10_000,
        lifetime_timeout: 30_000,
        terminal_linger: 100
      )

    assert run_id in Run.Supervisor.list_runs()

    ref = Process.monitor(pid)
    Run.cancel(run_id)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
  end

  defp item do
    %Item{id: "8", title: "t", prompt: "p", agent: :claude}
  end

  defp check(name, command), do: %Check{name: name, command: command, args: []}
end
