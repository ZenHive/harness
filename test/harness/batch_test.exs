defmodule Harness.BatchTest do
  # async: false because tests mutate singleton AgentRegistry and ProjectRegistry state.
  use ExUnit.Case, async: false

  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.OSProcess
  alias Harness.AgentAdapter.Run, as: AgentRun
  alias Harness.AgentRegistry
  alias Harness.Batch
  alias Harness.Batch.Result, as: BatchResult
  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.Roadmap.Item
  alias Harness.Run
  alias Harness.Run.Result
  alias Harness.Run.Worker, as: RunWorker
  alias Harness.Test.IdentityFakeAdapter, as: FakeAdapter

  @eventually_tries 150
  @eventually_delay_ms 20
  @run_timeout_ms 30_000
  @terminal_linger_ms 100
  @long_terminal_linger_ms 2_000

  defmodule QuotaAdapter do
    @moduledoc false
    @behaviour Harness.AgentAdapter

    @impl Harness.AgentAdapter
    def capabilities, do: %Capabilities{session_resume: true}

    @impl Harness.AgentAdapter
    def rule_channel, do: :none

    @impl Harness.AgentAdapter
    def build_command(%Invocation{} = invocation) do
      {:ok, {"/bin/echo", ["subscription quota exhausted for #{invocation.log_tag}"], []}}
    end

    @impl Harness.AgentAdapter
    def classify_message({port, {:data, data}}, %AgentRun{port: port} = run), do: {:output, data, run}

    def classify_message({port, {:exit_status, status}}, %AgentRun{port: port} = run), do: {:terminated, run, status}

    def classify_message(_message, _run), do: :ignore

    @impl Harness.AgentAdapter
    def terminate(%AgentRun{} = run), do: OSProcess.kill(run)
  end

  defmodule HeadroomAdapter do
    @moduledoc false
    @behaviour Harness.AgentAdapter

    @impl Harness.AgentAdapter
    def capabilities, do: %Capabilities{session_resume: true}

    @impl Harness.AgentAdapter
    def rule_channel, do: :none

    @impl Harness.AgentAdapter
    def build_command(%Invocation{} = invocation) do
      {:ok, {"/bin/sh", ["-c", "echo agent-output > agent_output.txt"], Map.to_list(invocation.env)}}
    end

    @impl Harness.AgentAdapter
    def classify_message({port, {:data, data}}, %AgentRun{port: port} = run), do: {:output, data, run}

    def classify_message({port, {:exit_status, status}}, %AgentRun{port: port} = run), do: {:terminated, run, status}

    def classify_message(_message, _run), do: :ignore

    @impl Harness.AgentAdapter
    def terminate(%AgentRun{} = run), do: OSProcess.kill(run)
  end

  defmodule TransientFirstAdapter do
    @moduledoc false
    @behaviour Harness.AgentAdapter

    @table :harness_batch_transient_attempts

    @impl Harness.AgentAdapter
    def capabilities, do: %Capabilities{session_resume: true}

    @impl Harness.AgentAdapter
    def rule_channel, do: :none

    @impl Harness.AgentAdapter
    def build_command(%Invocation{log_tag: log_tag}) do
      attempt = :ets.update_counter(@table, log_tag, {2, 1}, {log_tag, 0})

      script =
        if attempt == 1 do
          "echo broken > .git"
        else
          "echo agent-output > agent_output.txt"
        end

      {:ok, {"/bin/sh", ["-c", script], []}}
    end

    @impl Harness.AgentAdapter
    def classify_message({port, {:data, data}}, %AgentRun{port: port} = run), do: {:output, data, run}

    def classify_message({port, {:exit_status, status}}, %AgentRun{port: port} = run), do: {:terminated, run, status}

    def classify_message(_message, _run), do: :ignore

    @impl Harness.AgentAdapter
    def terminate(%AgentRun{} = run), do: OSProcess.kill(run)
  end

  setup_all do
    cleanup_gate_files()
    on_exit(&cleanup_gate_files/0)
    :ok
  end

  setup do
    AgentRegistry.reset()
    ProjectRegistry.reset()

    case :ets.info(:harness_batch_transient_attempts) do
      :undefined -> :ets.new(:harness_batch_transient_attempts, [:named_table, :set, :public])
      _ -> :ets.delete_all_objects(:harness_batch_transient_attempts)
    end

    :ok
  end

  test "runs a batch of tasks under the configured concurrency cap" do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    gate = gate_path()
    items = items(~w(1 2 3))

    batch_task =
      Task.async(fn ->
        Batch.run(
          items,
          ProjectFixture.from_repo(repo),
          FakeAdapter,
          batch_opts(base,
            max_concurrency: 2,
            adapter_opts: [command: {:write_then_wait_for_file, gate}]
          )
        )
      end)

    assert_eventually(fn ->
      assert ~w(1 2) = active_batch_task_ids(~w(1 2 3))
    end)

    File.write!(gate, "go")

    assert {:ok, %BatchResult{results: results}} = Task.await(batch_task, @run_timeout_ms)
    assert Enum.map(results, & &1.task_id) == ~w(1 2 3)
    assert Enum.all?(results, &match?(%Result{state: :done, reason: :approved}, &1))
  end

  test "frees a max-concurrency slot when a run reports its result before terminal linger exits" do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    started_at_ms = System.monotonic_time(:millisecond)

    assert {:ok, %BatchResult{results: results}} =
             Batch.run(
               items(~w(first second)),
               ProjectFixture.from_repo(repo),
               FakeAdapter,
               batch_opts(base,
                 max_concurrency: 1,
                 terminal_linger: @long_terminal_linger_ms
               )
             )

    elapsed_ms = System.monotonic_time(:millisecond) - started_at_ms

    assert Enum.map(results, &{&1.task_id, &1.state, &1.reason}) == [
             {"first", :done, :approved},
             {"second", :done, :approved}
           ]

    assert elapsed_ms < @long_terminal_linger_ms
  end

  @tag :capture_log
  test "a crashed active run still settles as run_crashed" do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    [item] = items(["crash"])

    batch_task =
      Task.async(fn ->
        Batch.run(
          [item],
          ProjectFixture.from_repo(repo),
          FakeAdapter,
          batch_opts(base,
            max_concurrency: 1,
            adapter_opts: [command: :sleep],
            idle_timeout: @run_timeout_ms,
            total_timeout: @run_timeout_ms
          )
        )
      end)

    "crash"
    |> await_batch_run_pid()
    |> Process.exit(:kill)

    assert {:ok, %BatchResult{results: [%Result{state: :failed, reason: {:run_crashed, _reason}}]}} =
             Task.await(batch_task, @run_timeout_ms)
  end

  @tag :capture_log
  test "a crashed batch worker process settles as run_crashed and persists the crash record" do
    # Kills the WORKER (Batch's spawned middle process), not the run gen_statem —
    # exercising the batch loop's own :DOWN settlement (settle_worker_down) instead
    # of the worker's await_run :DOWN branch.
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    [item] = items(["worker-crash"])
    store = file_store()

    batch_task =
      Task.async(fn ->
        Batch.run(
          [item],
          ProjectFixture.from_repo(repo),
          FakeAdapter,
          batch_opts(base,
            max_concurrency: 1,
            adapter_opts: [command: :sleep],
            idle_timeout: @run_timeout_ms,
            total_timeout: @run_timeout_ms,
            result_store: store
          )
        )
      end)

    # Wait until the run is active, so the worker is parked in its run-monitor
    # receive — then kill the worker out from under the batch loop.
    await_batch_run_pid("worker-crash")

    {:monitors, monitors} = Process.info(batch_task.pid, :monitors)
    worker_pids = for {:process, pid} <- monitors, do: pid
    assert [worker_pid] = worker_pids

    Process.exit(worker_pid, :kill)

    assert {:ok, %BatchResult{results: [%Result{state: :failed, reason: {:run_crashed, :killed}} = result]}} =
             Task.await(batch_task, @run_timeout_ms)

    # The crash record was persisted under the synthesized worker-crashed run id.
    assert {:ok, [record]} = ResultStore.list_run_records(store, run_id: result.run_id)
    assert record.run_id =~ "worker-crashed-worker-crash"
    assert record.reason == {:run_crashed, :killed}
  end

  test "keeps running after a rejected task and reports every task result" do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    items = items(~w(green red another-green))

    assert {:ok, %BatchResult{results: results}} =
             Batch.run(
               items,
               ProjectFixture.from_repo(repo),
               FakeAdapter,
               batch_opts(base,
                 max_concurrency: 2,
                 reviewer_adapter_opts: [command: {:review_by_task, ["red"]}]
               )
             )

    assert Enum.map(results, &{&1.task_id, &1.state, &1.reason}) == [
             {"green", :done, :approved},
             {"red", :failed, {:review_rejected, FakeAdapter.review_report("reject")}},
             {"another-green", :done, :approved}
           ]

    red = Enum.find(results, &(&1.task_id == "red"))
    assert red.review.verdict == :reject
  end

  test "REGRESSION (Task 67): pinned mode tail-slot continues when head-slot adapter is unavailable" do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    [item_a, item_b] = items(~w(slot-a slot-b))

    :ok = AgentRegistry.mark_unavailable(QuotaAdapter, {:test_setup, :pinned_partial})

    assert {:ok, %BatchResult{results: [first, second], events: events}} =
             Batch.run_pinned(
               [{item_a, QuotaAdapter}, {item_b, FakeAdapter}],
               ProjectFixture.from_repo(repo),
               batch_opts(base, max_concurrency: 2)
             )

    assert %Result{task_id: "slot-a", state: :failed, reason: {:no_available_agent, _}} = first
    assert %Result{task_id: "slot-b", state: :done, reason: :approved} = second

    assert {:no_available_agent, "slot-a", {:no_available_agent, [QuotaAdapter]}} in events
  end

  test "persists a batch result and queryable per-run records" do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    store = file_store()
    batch_id = batch_id()

    rejected_reason = {:review_rejected, FakeAdapter.review_report("reject")}

    assert {:ok, %BatchResult{batch_id: ^batch_id, results: results}} =
             Batch.run(
               items(~w(green red)),
               ProjectFixture.from_repo(repo),
               FakeAdapter,
               batch_opts(base,
                 batch_id: batch_id,
                 result_store: store,
                 max_concurrency: 2,
                 reviewer_adapter_opts: [command: {:review_by_task, ["red"]}]
               )
             )

    assert Enum.map(results, &{&1.task_id, &1.state, &1.reason}) == [
             {"green", :done, :approved},
             {"red", :failed, rejected_reason}
           ]

    assert {:ok, %BatchResult{batch_id: ^batch_id, results: reloaded}} = ResultStore.load_batch(batch_id, store)

    assert Enum.map(reloaded, &{&1.task_id, &1.state, &1.reason}) == [
             {"green", :done, :approved},
             {"red", :failed, rejected_reason}
           ]

    assert {:ok, [red_record]} = ResultStore.list_run_records(store, task_id: "red")
    assert red_record.agent == :claude
    assert red_record.adapter == FakeAdapter
    assert red_record.verdict == :reject
    assert red_record.reason == rejected_reason
    assert red_record.review_report == FakeAdapter.review_report("reject")
    assert red_record.review_ratings == FakeAdapter.review_ratings()
    assert red_record.agent_diff_size > 0
    assert red_record.duration_ms >= 0
  end

  # ---------------------------------------------------------------------------
  # REGRESSION (Task 57): worker spin loop settles via :no_available_agent,
  # not :run_crashed.
  #
  # `Batch.run_once_dispatch/5` is the worker's per-task entry point. The
  # parent `fill_slots/6` already gates on adapter availability — if every
  # adapter is unavailable at that moment, parent-side `settle_undispatchable/4`
  # fires and the worker never runs. The spin path is hit only under a race:
  # parent saw availability, spawned the worker, and the adapter flipped
  # unavailable before the worker's own `AgentRegistry.select/2`. Engineering
  # that race deterministically from a test is fragile, so this test calls
  # `run_once_dispatch/5` directly (it's `@doc false` but `def` for exactly
  # this reason) with an adapter that's been marked unavailable up front.
  # ---------------------------------------------------------------------------
  defmodule SpinExhaustedAdapter do
    @moduledoc false
    @behaviour Harness.AgentAdapter

    @impl Harness.AgentAdapter
    def capabilities, do: %Capabilities{session_resume: true}

    @impl Harness.AgentAdapter
    def rule_channel, do: :none

    @impl Harness.AgentAdapter
    def build_command(_invocation), do: {:ok, {"/bin/true", [], []}}

    @impl Harness.AgentAdapter
    def classify_message(_message, _run), do: :ignore

    @impl Harness.AgentAdapter
    def terminate(_run), do: :ok
  end

  test "REGRESSION (Task 57): spin exhaustion settles {:no_available_agent, :spin_exhausted}, not {:run_crashed, _}" do
    AgentRegistry.mark_unavailable(SpinExhaustedAdapter, {:test_setup, :unavailable})
    on_exit(fn -> AgentRegistry.mark_available(SpinExhaustedAdapter) end)

    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    [item] = items(["spin"])

    result =
      Batch.run_once_dispatch(
        item,
        ProjectFixture.from_repo(repo),
        [SpinExhaustedAdapter],
        batch_opts(base, []),
        0
      )

    # Audit (Task 57): before the fix this returned
    # `{:run_crashed, :dispatch_spin_exhausted}`, which falsely implied a
    # worker crash. The settled reason now matches the parent's
    # `fill_slots/6 → settle_undispatchable/4` undispatchable shape.
    assert %Result{state: :failed, reason: {:no_available_agent, :spin_exhausted}} = result
    assert result.task_id == "spin"
  end

  # Task 163: adapter fail-over is no longer triggered by quota regexes — the
  # cross-family reviewer judges what an empty diff means, and Batch reads that
  # judgment mechanically ({:review_stuck, _} reason + empty implementer diff).
  test "reviewer-stuck with an empty diff fails over to the next adapter family" do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    [item] = items(["starved"])

    # The reviewer double judges by what the implementer left behind: an
    # agent_output.txt means real work (approve); nothing means the implementer
    # delivered nothing (no artifact → review_stuck). QuotaAdapter writes
    # nothing; HeadroomAdapter writes agent_output.txt.
    assert {:ok, %BatchResult{results: [result], events: events}} =
             Batch.run(
               [item],
               ProjectFixture.from_repo(repo),
               [QuotaAdapter, HeadroomAdapter],
               batch_opts(base,
                 max_concurrency: 1,
                 reviewer_adapter_opts: [command: {:review_if_file, "agent_output.txt"}]
               )
             )

    # The item was re-run on the next adapter family and delivered green.
    assert %Result{task_id: "starved", state: :done, reason: :approved} = result

    # The starved adapter is benched with the review-stuck report — the
    # orchestrator reads WHY from the reviewer outcome, never from a harness regex.
    assert [{QuotaAdapter, {:review_stuck, "starved", report}}] = AgentRegistry.list_unavailable()
    assert report =~ "verdict artifact"

    # The event trail carries the same judgment.
    assert {:adapter_unavailable, QuotaAdapter, {:review_stuck, "starved", report}} in events
    assert {:failover, "starved", QuotaAdapter, HeadroomAdapter} in events
  end

  test "retries adapter selection when start_run loses a concurrent availability race" do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()

    :ok = AgentRegistry.mark_unavailable(QuotaAdapter, :concurrent_batch)

    assert {:error, {:no_available_agent, [QuotaAdapter]}} =
             Run.Supervisor.start_run(
               hd(items(["precheck"])),
               ProjectFixture.from_repo(repo),
               QuotaAdapter,
               batch_opts(base, [])
             )

    AgentRegistry.reset()

    batch =
      Task.async(fn ->
        Batch.run(
          items(["race-task"]),
          ProjectFixture.from_repo(repo),
          [QuotaAdapter, HeadroomAdapter],
          batch_opts(base,
            max_concurrency: 1,
            reviewer_adapter_opts: [command: {:review_if_file, "agent_output.txt"}]
          )
        )
      end)

    for _ <- 1..100 do
      :ok = AgentRegistry.mark_unavailable(QuotaAdapter, :concurrent_batch)
      Process.sleep(0)
    end

    assert {:ok, %BatchResult{results: [%Result{} = result]}} = Task.await(batch, @run_timeout_ms)
    assert result.state == :done
    assert result.reason == :approved
    refute AgentRegistry.available?(QuotaAdapter)
    assert AgentRegistry.available?(HeadroomAdapter)
  end

  test "a settled rejection is returned in one pass — Batch never re-runs a settled verdict" do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()

    assert {:ok, %BatchResult{results: [%Result{} = result]}} =
             Batch.run(
               items(["red"]),
               ProjectFixture.from_repo(repo),
               FakeAdapter,
               batch_opts(base,
                 max_concurrency: 1,
                 reviewer_adapter_opts: [command: {:review, "reject"}]
               )
             )

    assert {result.state, result.reason} ==
             {:failed, {:review_rejected, FakeAdapter.review_report("reject")}}
  end

  test "a mechanical failure settles :failed in one pass — mechanical retry belongs to the Oban dispatch layer" do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()

    assert {:ok, %BatchResult{results: [%Result{} = result]}} =
             Batch.run(
               items(["transient-task"]),
               ProjectFixture.from_repo(repo),
               TransientFirstAdapter,
               batch_opts(base, max_concurrency: 1)
             )

    assert result.state == :failed
    assert match?({:commit_failed, _}, result.reason)
    assert :ets.lookup(:harness_batch_transient_attempts, "transient-task") == [{"transient-task", 1}]
  end

  test "concurrent batches survive adapter unavailability during dispatch" do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()

    tasks =
      for id <- ~w(race-a race-b race-c) do
        Task.async(fn ->
          Batch.run(
            items([id]),
            ProjectFixture.from_repo(repo),
            QuotaAdapter,
            batch_opts(base, max_concurrency: 1)
          )
        end)
      end

    assert Enum.all?(tasks, fn task ->
             match?({:ok, %BatchResult{results: [_]}}, Task.await(task, @run_timeout_ms))
           end)
  end

  test "resolves a registered project name" do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    project = ProjectFixture.from_repo(repo, name: "registered-batch")

    assert :ok = ProjectRegistry.register(project)

    assert {:ok, %BatchResult{results: [result]}} =
             Batch.run(
               items(["by-name"]),
               "registered-batch",
               FakeAdapter,
               batch_opts(base, max_concurrency: 1)
             )

    assert result.state == :done
  end

  test "uses project.concurrency_cap when max_concurrency is omitted" do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    gate = gate_path()
    project = ProjectFixture.from_repo(repo, name: "capped", concurrency_cap: 1)

    batch_task =
      Task.async(fn ->
        Batch.run(
          items(~w(1 2)),
          project,
          FakeAdapter,
          batch_opts(base, adapter_opts: [command: {:write_then_wait_for_file, gate}])
        )
      end)

    assert_eventually(fn ->
      assert match?([_], active_batch_task_ids(~w(1 2)))
    end)

    File.write!(gate, "go")
    assert {:ok, %BatchResult{max_concurrency: 1, results: results}} = Task.await(batch_task, @run_timeout_ms)
    assert match?([_, _], results)
  end

  test "dispatch applies the run worker in-flight uniqueness spec to every job" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-batch-unique", name: "batch-unique")

    Application.put_env(:harness, :oban_insert, fn changeset ->
      send(parent, {:unique, Ecto.Changeset.get_change(changeset, :unique)})
      {:ok, Ecto.Changeset.apply_action!(changeset, :insert)}
    end)

    on_exit(fn -> Application.delete_env(:harness, :oban_insert) end)

    assert {:ok, [_job]} =
             Batch.dispatch(project, [%Item{id: "286", title: "Task 286", prompt: "do task 286", agent: :claude}])

    assert_received {:unique, unique}
    assert unique.keys == RunWorker.unique_opts()[:keys]
    assert unique.states == RunWorker.unique_opts()[:states]
    assert unique.period == RunWorker.unique_opts()[:period]
  end

  defp batch_opts(base, overrides) do
    Keyword.merge(
      [
        base_dir: base,
        adapter_opts: [command: :write],
        reviewer: FakeAdapter,
        reviewer_adapter_opts: [command: {:review, "approve"}],
        total_timeout: @run_timeout_ms,
        idle_timeout: @run_timeout_ms,
        lifetime_timeout: @run_timeout_ms,
        terminal_linger: @terminal_linger_ms
      ],
      overrides
    )
  end

  defp items(ids) do
    Enum.map(ids, fn id ->
      %Item{id: id, title: "Task #{id}", prompt: "do task #{id}", agent: :claude}
    end)
  end

  defp gate_path do
    path = Path.join(System.tmp_dir!(), "harness-batch-gate-#{System.unique_integer([:positive])}")
    on_exit(fn -> cleanup_gate(path) end)
    path
  end

  defp cleanup_gate_files do
    System.tmp_dir!()
    |> Path.join("harness-batch-gate-*")
    |> Path.wildcard()
    |> Enum.each(&File.rm/1)
  end

  # Task 70: gate-file hygiene. On normal completion the gate file is left
  # behind; on a test crash before the gate is written the spawned `/bin/sh`
  # shells survive Port owner death and spin forever. Best-effort: kill any
  # polling shell by command-line match, then delete the gate file.
  defp cleanup_gate(path) do
    _ = System.cmd("pkill", ["-f", Path.basename(path)], stderr_to_stdout: true)
    File.rm(path)
  end

  defp batch_id, do: "batch-#{System.unique_integer([:positive])}"

  defp file_store do
    {Harness.ResultStore.Memory,
     root:
       Path.join(
         System.tmp_dir!(),
         "harness-result-store-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
       )}
  end

  defp active_batch_task_ids(batch_ids) do
    batch_ids = MapSet.new(batch_ids)

    Run.Supervisor.list_runs()
    |> Enum.flat_map(fn run_id ->
      case Run.status(run_id) do
        {:ok, %{task_id: task_id}} -> [task_id]
        {:error, :not_found} -> []
      end
    end)
    |> Enum.filter(&MapSet.member?(batch_ids, &1))
    |> Enum.sort()
  end

  defp await_batch_run_pid(task_id, tries \\ @eventually_tries)

  defp await_batch_run_pid(task_id, tries) when tries > 1 do
    case batch_run_pid(task_id) do
      {:ok, pid} ->
        pid

      :error ->
        Process.sleep(@eventually_delay_ms)
        await_batch_run_pid(task_id, tries - 1)
    end
  end

  defp await_batch_run_pid(task_id, 1) do
    case batch_run_pid(task_id) do
      {:ok, pid} -> pid
      :error -> flunk("run for task #{task_id} never became active")
    end
  end

  defp batch_run_pid(task_id) do
    Run.Supervisor.list_runs()
    |> Enum.find_value(fn run_id ->
      with {:ok, %{task_id: ^task_id}} <- Run.status(run_id),
           [{pid, _value}] <- Registry.lookup(Harness.Run.Registry, run_id) do
        {:ok, pid}
      else
        _other -> nil
      end
    end)
    |> case do
      nil -> :error
      {:ok, pid} -> {:ok, pid}
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
