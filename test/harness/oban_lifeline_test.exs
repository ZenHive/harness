defmodule Harness.ObanLifelineTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Harness.AgentAdapter.Capabilities
  alias Harness.Config
  alias Harness.GitFixture
  alias Harness.Oban, as: HarnessOban
  alias Harness.ProjectFixture
  alias Harness.Run.Supervisor, as: RunSupervisor
  alias Harness.Run.Worker
  alias Oban.Plugins.Lifeline

  defmodule BlockingAdapter do
    @moduledoc false
    use Harness.AgentAdapter

    @impl true
    @spec capabilities() :: Capabilities.t()
    def capabilities, do: %Capabilities{}

    @impl true
    @spec rule_channel() :: Harness.AgentAdapter.rule_channel()
    def rule_channel, do: :none

    @impl true
    @spec build_command(Harness.AgentAdapter.Invocation.t()) :: {:ok, Harness.AgentAdapter.command()}
    def build_command(invocation) do
      send(Keyword.fetch!(invocation.adapter_opts, :owner), {:adapter_waiting, self()})

      receive do
        :release -> {:ok, {"/bin/true", [], []}}
      end
    end
  end

  @tag :integration
  test "the installed plugin preserves a live dispatch through its lifetime and rescues abandoned queues" do
    start_supervised!(Harness.Repo)
    :ok = Sandbox.checkout(Harness.Repo)
    Sandbox.mode(Harness.Repo, {:shared, self()})

    opts = HarnessOban.oban_opts()
    {Lifeline, rescue_opts} = List.keyfind(opts[:plugins], Lifeline, 0)
    lifetime = Config.get({:run, :lifetime_timeout})
    bound = lifetime + to_timeout(minute: 5)
    assert rescue_opts[:rescue_after] == bound

    start_supervised!(
      {Oban,
       name: __MODULE__,
       repo: Harness.Repo,
       queues: false,
       plugins: [{Oban.Lifeline, Keyword.put(rescue_opts, :interval, to_timeout(day: 1))}],
       notifier: Oban.Notifiers.Isolated,
       peer: Oban.Peers.Isolated,
       stage_interval: :infinity}
    )

    project = ProjectFixture.from_repo(GitFixture.init_repo(), name: "lifeline-live")
    item = %Harness.Roadmap.Item{id: "439", title: "Lifeline", prompt: "Wait for the test", agent: :claude}

    {:ok, run_id, pid} =
      RunSupervisor.start_run(item, project, BlockingAdapter,
        base_dir: GitFixture.tmp_base(),
        adapter_opts: [owner: self()],
        total_timeout: nil,
        idle_timeout: nil
      )

    on_exit(fn ->
      if Process.alive?(pid), do: :gen_statem.stop(pid)
    end)

    assert_receive {:adapter_waiting, adapter_pid}, 10_000
    assert Process.alive?(adapter_pid)
    assert {:ok, %{state: :running}} = Harness.Run.status(run_id)

    now = DateTime.utc_now()
    args = %{project_name: project.name, item_id: item.id, run_id: run_id}
    live = executing!(Worker.new(args, queue: "project_lifeline-live", unique: Worker.unique_opts()), now, lifetime)

    abandoned =
      for {worker, queue} <- [
            {Worker, "project_abandoned"},
            {Harness.Lander.Worker, "landing_abandoned"},
            {Harness.Audit.Worker, "audit"}
          ] do
        executing!(worker.new(%{run_id: "abandoned"}, queue: queue), now, bound + 1_000)
      end

    plugin = Oban.Registry.whereis(__MODULE__, {:plugin, Oban.Lifeline})
    assert is_pid(plugin)
    assert Oban.Peer.leader?(Oban.config(__MODULE__))
    send(plugin, :rescue)
    :sys.get_state(plugin)

    assert %{state: "executing", attempt: 1} = Harness.Repo.reload!(live)
    assert Process.alive?(adapter_pid)
    assert {:ok, %{state: :running}} = Harness.Run.status(run_id)

    for job <- abandoned do
      assert %{state: "available", attempt: 1} = Harness.Repo.reload!(job)
    end

    # The original row still owns the unique identity after a real rescue tick.
    duplicate = Oban.insert!(__MODULE__, Worker.new(args, queue: live.queue, unique: Worker.unique_opts()))
    assert duplicate.conflict?
    assert duplicate.id == live.id

    assert :ok = HarnessOban.rescue_orphaned_run_jobs()
    assert %{state: "executing"} = Harness.Repo.reload!(live)

    ref = Process.monitor(pid)
    :gen_statem.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    # Registry removes dead owners in its partition process, asynchronously.
    for {_id, partition, _type, _modules} <- Supervisor.which_children(Harness.Run.Registry) do
      :sys.get_state(partition)
    end

    refute run_id in RunSupervisor.list_runs()
    assert :ok = HarnessOban.rescue_orphaned_run_jobs()
    assert %{state: "available", attempt: 1} = Harness.Repo.reload!(live)
  end

  defp executing!(changeset, now, age) do
    changeset
    |> Ecto.Changeset.change(state: "executing", attempt: 1, attempted_at: DateTime.add(now, -age, :millisecond))
    |> Harness.Repo.insert!()
  end
end
