defmodule Harness.Run.ShutdownTest do
  use ExUnit.Case, async: false

  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.ResultStore
  alias Harness.Roadmap.Item
  alias Harness.Run
  alias Harness.Run.Admission
  alias Harness.Run.Result
  alias Harness.Test.IdentityFakeAdapter
  alias Harness.Test.ShutdownAdapter, as: ControlledAdapter

  setup do
    sup =
      start_supervised!(
        {Run.Supervisor, name: __MODULE__.Supervisor, admission: __MODULE__.Admission, runs: __MODULE__.Runs}
      )

    store = {ResultStore.Memory, scope: make_ref()}
    ResultStore.Memory.reset(elem(store, 1))
    %{sup: sup, store: store, admission: __MODULE__.Admission}
  end

  for role <- [:running, :reviewing, :recovering] do
    test "supervisor stop settles #{role}, keeps committed evidence and kills its agent", ctx do
      role = unquote(role)
      {id, pid, driver, cwd} = start_controlled(ctx, role)
      handle = spawn_agent(pid, driver, role)
      driver_ref = Process.monitor(driver)
      run_ref = Process.monitor(pid)
      sha = GitFixture.git!(cwd, ["rev-parse", "HEAD"])
      started = System.monotonic_time(:millisecond)

      assert :ok = Supervisor.stop(ctx.sup)
      assert System.monotonic_time(:millisecond) - started < 17_000
      assert_receive {:harness_run, ^id, %Result{state: :failed, reason: {:shutdown, ^role}}}
      assert_receive {:DOWN, ^run_ref, :process, ^pid, :shutdown}
      assert_receive {:DOWN, ^driver_ref, :process, ^driver, _}
      assert {_, 1} = System.cmd("kill", ["-0", to_string(handle.os_pid)], stderr_to_stdout: true)
      assert File.dir?(cwd)
      assert GitFixture.git!(cwd, ["rev-parse", "HEAD"]) == sha
      assert {:ok, [record]} = ResultStore.list_run_records(ctx.store, run_id: id)
      assert record.reason == {:shutdown, role}
    end
  end

  test "one supervisor settles concurrent implementer, reviewer and recovery processes", ctx do
    runs =
      Enum.map([:running, :reviewing, :recovering], fn role ->
        {id, pid, driver, _cwd} = start_controlled(ctx, role)
        {id, role, spawn_agent(pid, driver, role)}
      end)

    assert :ok = Supervisor.stop(ctx.sup)

    for {id, role, handle} <- runs do
      assert_receive {:harness_run, ^id, %Result{reason: {:shutdown, ^role}}}
      assert {:ok, [record]} = ResultStore.list_run_records(ctx.store, run_id: id)
      assert record.reason == {:shutdown, role}
      assert {_, 1} = System.cmd("kill", ["-0", to_string(handle.os_pid)], stderr_to_stdout: true)
    end
  end

  test "shutdown owns the optional live discernment grader as well as the implementer", ctx do
    {id, pid, driver, cwd} =
      start_controlled(ctx, :running,
        in_run_discernment: [
          enabled: true,
          grader: ControlledAdapter,
          adapter_opts: [owner: self()],
          weight: 9,
          sample_interval_ms: 60_000
        ]
      )

    implementer = spawn_agent(pid, driver, :running)
    send(pid, {:transcript_chunk, "partial implementation"})
    assert_receive {:invoking, grader, ^cwd}, 5_000
    grader_handle = spawn_agent(pid, grader, :discernment)
    assert :ok = Supervisor.stop(ctx.sup)
    assert_receive {:harness_run, ^id, %Result{reason: {:shutdown, :running}}}

    for handle <- [implementer, grader_handle] do
      assert {_, 1} = System.cmd("kill", ["-0", to_string(handle.os_pid)], stderr_to_stdout: true)
    end
  end

  test "shutdown fences invocation admission while an admitted spawn is completing", ctx do
    {id, pid, driver, cwd} = start_controlled(ctx, :reviewing)
    token = Admission.token(ctx.admission)
    stop = Task.async(fn -> Supervisor.stop(ctx.sup) end)
    # A call queued after the close witness proves the admission boundary rejects
    # every role, including reprompts/rotation, before adapter build_command.
    await_closed(token)

    for role <- ["implementer", "reviewer-reprompt", "reviewer-rotation", "recovery", "discernment"] do
      invocation = %Harness.AgentAdapter.Invocation{
        cwd: cwd,
        prompt: "shutdown race",
        log_tag: role,
        adapter_opts: [owner: self()]
      }

      assert {:error, :shutdown} = Harness.AgentDriver.run(ControlledAdapter, invocation, admission: ctx.admission)
    end

    assert {:error, :shutdown} = Admission.acquire(ctx.admission)
    assert {:error, :shutdown} = Admission.start_run(ctx.admission, {Task, fn -> flunk("admitted during shutdown") end})
    refute_receive {:invoking, _, _}, 20
    handle = spawn_agent(pid, driver, :reviewing)
    assert :ok = Task.await(stop, 17_000)
    assert_receive {:harness_run, ^id, %Result{reason: {:shutdown, :reviewing}}}
    assert {_, 1} = System.cmd("kill", ["-0", to_string(handle.os_pid)], stderr_to_stdout: true)
  end

  test "a hung pre-spawn invocation is bounded and reported", ctx do
    {id, _pid, driver, _cwd} = start_controlled(ctx, :running)
    ref = Process.monitor(driver)

    log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = Supervisor.stop(ctx.sup) end)
    assert log =~ "exceeded 5000ms spawn grace"
    assert_receive {:DOWN, ^ref, :process, ^driver, :killed}
    assert_receive {:harness_run, ^id, %Result{reason: {:shutdown, :running}}}
    assert {:ok, [_]} = ResultStore.list_run_records(ctx.store, run_id: id)
  end

  defmodule UnavailableStore do
    @moduledoc false
    @spec record_run(Harness.Run.LogRecord.t(), keyword()) :: {:error, atom()}
    def record_run(_record, _opts), do: {:error, :shutdown_test_store_unavailable}
  end

  test "persistence failure is visible and spills the attributable shutdown record", ctx do
    root = Path.join(GitFixture.tmp_base(), "dead-letter")
    previous = Application.fetch_env(:harness, :result_store_dead_letter)
    Application.put_env(:harness, :result_store_dead_letter, root: root)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:harness, :result_store_dead_letter, value)
        :error -> Application.delete_env(:harness, :result_store_dead_letter)
      end
    end)

    {id, pid, driver, _cwd} = start_controlled(%{ctx | store: UnavailableStore}, :reviewing)
    spawn_agent(pid, driver, :reviewing)
    log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = Supervisor.stop(ctx.sup) end)
    assert log =~ "shutdown_test_store_unavailable"
    assert {:ok, %{record: record}} = ResultStore.DeadLetter.load(id)
    assert record.reason == {:shutdown, :reviewing}
    assert_receive {:harness_run, ^id, %Result{reason: {:shutdown, :reviewing}}}
  end

  @tag timeout: 60_000
  test "actual Application.stop settles before application-owned stores terminate" do
    {output, status} =
      System.cmd("mix", ["run", "--no-start", "test/support/shutdown_application_probe.exs"],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "shutdown application probe passed"
  end

  defp start_controlled(ctx, role, overrides \\ []) do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    project = ProjectFixture.from_repo(repo)

    opts = [
      admission: ctx.admission,
      result_store: ctx.store,
      base_dir: base,
      idle_timeout: 60_000,
      total_timeout: 60_000,
      lifetime_timeout: 90_000,
      reviewer_spawn_timeout: 60_000,
      reviewing_idle_timeout: 60_000,
      reviewer: ControlledAdapter,
      reviewer_adapter_opts: [owner: self()]
    ]

    {adapter, extra} =
      case role do
        :running ->
          {ControlledAdapter, [adapter_opts: [owner: self()]]}

        :reviewing ->
          {IdentityFakeAdapter, [adapter_opts: [command: :write]]}

        :recovering ->
          {IdentityFakeAdapter,
           [checkout_pollution_check: true, adapter_opts: [command: {:write_and_pollute_checkout, repo}]]}
      end

    assert {:ok, id, pid} =
             Run.Supervisor.start_run(
               %Item{id: "427", title: "shutdown", prompt: "work", agent: :claude},
               project,
               adapter,
               Keyword.merge(opts, extra) ++ overrides
             )

    assert_receive {:invoking, driver, cwd}, 10_000
    # Pin a real commit even in the implementer/recovery case.
    File.write!(Path.join(cwd, "retained.txt"), "retained\n")
    GitFixture.git!(cwd, ["add", "retained.txt"])
    GitFixture.git!(cwd, ["commit", "-m", "retained evidence"])
    {id, pid, driver, cwd}
  end

  defp spawn_agent(pid, driver, role) do
    :erlang.trace(pid, true, [:receive, {:tracer, self()}])
    send(driver, :spawn)

    message =
      case role do
        :running -> :run_handle
        :reviewing -> :reviewer_handle
        :recovering -> :recovery_handle
        :discernment -> :discernment_handle
      end

    assert_receive {:trace, ^pid, :receive, {^message, handle}}, 5_000
    handle
  end

  defp await_closed(token, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    assert System.monotonic_time(:millisecond) < deadline, "admission did not close"

    if Admission.closed?(token) do
      :ok
    else
      receive do
      after
        1 -> await_closed(token, deadline)
      end
    end
  end
end
