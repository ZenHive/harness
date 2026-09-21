import ExUnit.Assertions

alias Harness.GitFixture
alias Harness.ProjectFixture
alias Harness.Run
alias Harness.Test.ShutdownAdapter

defmodule ShutdownProbeStore do
  @moduledoc false
  use GenServer

  @spec start_link(pid()) :: GenServer.on_start()
  def start_link(owner), do: GenServer.start_link(__MODULE__, owner, name: __MODULE__)

  @impl true
  @spec init(pid()) :: {:ok, pid()}
  def init(owner) do
    Process.flag(:trap_exit, true)
    {:ok, owner}
  end

  @spec record_run(Harness.Run.LogRecord.t(), keyword()) :: :ok
  def record_run(record, _opts), do: GenServer.call(__MODULE__, {:record, record})

  @impl true
  @spec handle_call(term(), GenServer.from(), pid()) :: {:reply, :ok, pid()}
  def handle_call({:record, record}, _from, owner) do
    assert Process.whereis(Harness.ProjectRegistry)
    assert Process.whereis(Harness.Run.TaskSupervisor)
    send(owner, {:stored, record})
    {:reply, :ok, owner}
  end

  # Added last: without prep_stop this store would die before Run.Supervisor.
  @impl true
  @spec terminate(term(), pid()) :: atom()
  def terminate(_reason, owner), do: send(owner, :store_stopped)
end

root = Path.join(System.tmp_dir!(), "harness-shutdown-probe-#{System.pid()}")
File.mkdir_p!(root)
Application.put_env(:harness, :test_fixture_root, root)
{:ok, _apps} = Application.ensure_all_started(:harness)
{:ok, _store} = Supervisor.start_child(Harness.Supervisor, {ShutdownProbeStore, self()})
repo = Path.join(root, "repo")
File.mkdir_p!(repo)
GitFixture.git!(repo, ["init", "-q", "--initial-branch=main"])
GitFixture.git!(repo, ["config", "user.email", "shutdown@example.com"])
GitFixture.git!(repo, ["config", "user.name", "Shutdown Test"])
File.write!(Path.join(repo, "README.md"), "shutdown fixture")
GitFixture.git!(repo, ["add", "README.md"])
GitFixture.git!(repo, ["commit", "-m", "fixture"])
project = ProjectFixture.from_repo(repo)
item = %Harness.Roadmap.Item{id: "427", title: "shutdown", prompt: "work", agent: :claude}

{:ok, id, pid} =
  Run.Supervisor.start_run(item, project, ShutdownAdapter,
    base_dir: Path.join(root, "worktrees"),
    result_store: ShutdownProbeStore,
    adapter_opts: [owner: self()],
    lifetime_timeout: 60_000
  )

assert_receive {:invoking, driver, cwd}, 10_000
:erlang.trace(pid, true, [:receive, {:tracer, self()}])
send(driver, :spawn)
assert_receive {:trace, ^pid, :receive, {:run_handle, handle}}, 5_000
started = System.monotonic_time(:millisecond)
assert :ok = Application.stop(:harness)
assert System.monotonic_time(:millisecond) - started < 17_000
assert_receive {:stored, %{run_id: ^id, reason: {:shutdown, :running}}}
assert_receive {:harness_run, ^id, %{state: :failed, reason: {:shutdown, :running}}}
assert_receive :store_stopped
assert {_, 1} = System.cmd("kill", ["-0", to_string(handle.os_pid)], stderr_to_stdout: true)
assert File.dir?(cwd)
File.rm_rf!(root)
IO.puts("shutdown application probe passed")
