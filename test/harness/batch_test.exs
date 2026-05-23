defmodule Harness.BatchTest do
  use ExUnit.Case, async: false

  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.OSProcess
  alias Harness.AgentAdapter.Run, as: AgentRun
  alias Harness.AgentRegistry
  alias Harness.Batch
  alias Harness.Batch.Result, as: BatchResult
  alias Harness.FakeAdapter
  alias Harness.GitFixture
  alias Harness.ResultStore
  alias Harness.Roadmap.Item
  alias Harness.Run
  alias Harness.Run.Result
  alias Harness.Verification.Check

  @eventually_tries 150
  @eventually_delay_ms 20
  @run_timeout_ms 30_000
  @terminal_linger_ms 100

  defmodule QuotaAdapter do
    @moduledoc false
    @behaviour Harness.AgentAdapter

    @impl Harness.AgentAdapter
    def capabilities, do: %Capabilities{session_resume: true}

    @impl Harness.AgentAdapter
    def build_command(%Invocation{} = invocation) do
      {:ok, {"/bin/echo", ["subscription quota exhausted for #{invocation.task_id}"], []}}
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

  setup do
    AgentRegistry.reset()
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
          repo,
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
    assert Enum.all?(results, &match?(%Result{state: :done, reason: :passed}, &1))
  end

  test "keeps running after a red task and reports every task result" do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    items = items(~w(green red another-green))

    assert {:ok, %BatchResult{results: results}} =
             Batch.run(
               items,
               repo,
               FakeAdapter,
               batch_opts(base,
                 max_concurrency: 2,
                 adapter_opts: [command: {:write_status_by_task, ["red"]}],
                 checks: [check("status", "grep", ["pass", "status.txt"])]
               )
             )

    assert Enum.map(results, &{&1.task_id, &1.state, &1.reason}) == [
             {"green", :done, :passed},
             {"red", :failed, :verification_red},
             {"another-green", :done, :passed}
           ]

    red = Enum.find(results, &(&1.task_id == "red"))
    assert red.verdict.status == :fail
  end

  test "settles queued items when every capable adapter is quota-exhausted mid-flight" do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()

    assert {:ok, %BatchResult{results: results, events: events}} =
             Batch.run(
               items(~w(first second third)),
               repo,
               [QuotaAdapter],
               batch_opts(base,
                 max_concurrency: 1,
                 checks: [check("ok", "true", [])]
               )
             )

    assert Enum.map(results, & &1.task_id) == ~w(first second third)

    [first | undispatched] = results

    assert first.state == :failed
    assert AgentRegistry.quota_exhausted?(first.agent_outcome)

    assert Enum.all?(undispatched, &match?(%Result{state: :failed, reason: {:no_available_agent, _}}, &1))

    assert {:adapter_unavailable, QuotaAdapter, {:quota_exhausted, "first"}} in events
    assert {:no_available_agent, "second", {:no_available_agent, [QuotaAdapter]}} in events
    assert {:no_available_agent, "third", {:no_available_agent, [QuotaAdapter]}} in events

    refute AgentRegistry.available?(QuotaAdapter)
  end

  test "persists a batch result and queryable per-run records" do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    store = file_store()
    batch_id = batch_id()

    assert {:ok, %BatchResult{batch_id: ^batch_id, results: results}} =
             Batch.run(
               items(~w(green red)),
               repo,
               FakeAdapter,
               batch_opts(base,
                 batch_id: batch_id,
                 result_store: store,
                 max_concurrency: 2,
                 adapter_opts: [command: {:write_status_by_task, ["red"]}],
                 checks: [check("status", "grep", ["pass", "status.txt"])]
               )
             )

    assert Enum.map(results, &{&1.task_id, &1.state, &1.reason}) == [
             {"green", :done, :passed},
             {"red", :failed, :verification_red}
           ]

    assert {:ok, %BatchResult{batch_id: ^batch_id, results: reloaded}} = ResultStore.load_batch(batch_id, store)

    assert Enum.map(reloaded, &{&1.task_id, &1.state, &1.reason}) == [
             {"green", :done, :passed},
             {"red", :failed, :verification_red}
           ]

    assert {:ok, [red_record]} = ResultStore.list_run_records(store, task_id: "red")
    assert red_record.agent == :claude
    assert red_record.adapter == FakeAdapter
    assert red_record.verdict == :fail
    assert red_record.reason == :verification_red
    assert red_record.repair_attempts == 0
    assert red_record.first_attempt_failed_check_count == 1
    assert red_record.agent_diff_size > 0
    assert red_record.duration_ms >= 0

    assert red_record.failure_cause == %{
             reason: :verification_red,
             failed_checks: [%{name: "status", kind: :exited, exit_status: 1}]
           }
  end

  test "fails over from a quota-exhausted adapter to a capable adapter with headroom" do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()

    assert {:ok, %BatchResult{results: [%Result{} = result], events: events}} =
             Batch.run(
               items(["quota-task"]),
               repo,
               [QuotaAdapter, HeadroomAdapter],
               batch_opts(base,
                 max_concurrency: 1,
                 checks: [check("ok", "true", [])]
               )
             )

    assert result.state == :done
    assert result.reason == :passed
    refute AgentRegistry.available?(QuotaAdapter)
    assert AgentRegistry.available?(HeadroomAdapter)

    assert {:adapter_unavailable, QuotaAdapter, {:quota_exhausted, "quota-task"}} in events
    assert {:failover, "quota-task", QuotaAdapter, HeadroomAdapter} in events
  end

  test "persists quota-blocked attempts and the fail-over event chain" do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    store = file_store()
    batch_id = batch_id()

    assert {:ok, %BatchResult{events: events}} =
             Batch.run(
               items(["quota-task"]),
               repo,
               [QuotaAdapter, HeadroomAdapter],
               batch_opts(base,
                 batch_id: batch_id,
                 result_store: store,
                 max_concurrency: 1,
                 checks: [check("ok", "true", [])]
               )
             )

    assert {:adapter_unavailable, QuotaAdapter, {:quota_exhausted, "quota-task"}} in events
    assert {:failover, "quota-task", QuotaAdapter, HeadroomAdapter} in events

    assert {:ok, %BatchResult{events: reloaded_events}} = ResultStore.load_batch(batch_id, store)
    assert {:failover, "quota-task", QuotaAdapter, HeadroomAdapter} in reloaded_events

    assert {:ok, records} = ResultStore.list_run_records(store, task_id: "quota-task")
    assert length(records) == 2

    quota_record = Enum.find(records, &(&1.adapter == QuotaAdapter))
    headroom_record = Enum.find(records, &(&1.adapter == HeadroomAdapter))

    assert quota_record.state == :failed
    assert quota_record.reason == :no_changes
    assert quota_record.failure_cause == %{reason: :no_changes, failed_checks: []}
    assert quota_record.agent_output =~ "quota exhausted"

    assert headroom_record.state == :done
    assert headroom_record.reason == :passed
  end

  defp batch_opts(base, overrides) do
    Keyword.merge(
      [
        base_dir: base,
        adapter_opts: [command: :write],
        checks: [check("ok", "true", [])],
        total_timeout: @run_timeout_ms,
        idle_timeout: @run_timeout_ms,
        lifetime_timeout: @run_timeout_ms,
        verification_timeout: @run_timeout_ms,
        terminal_linger: @terminal_linger_ms,
        # Batch orchestration is the unit under test, not the repair loop — a red
        # task must settle :verification_red on its first verdict. With repair
        # enabled it would resume, the fixture would produce no fresh diff, and
        # the run would settle :no_changes instead. Repair is covered by run_test.
        max_repair_attempts: 0
      ],
      overrides
    )
  end

  defp items(ids) do
    Enum.map(ids, fn id ->
      %Item{id: id, title: "Task #{id}", prompt: "do task #{id}", agent: :claude}
    end)
  end

  defp check(name, command, args), do: %Check{name: name, command: command, args: args}

  defp gate_path do
    Path.join(System.tmp_dir!(), "harness-batch-gate-#{System.unique_integer([:positive])}")
  end

  defp batch_id, do: "batch-#{System.unique_integer([:positive])}"

  defp file_store do
    {Harness.ResultStore.File,
     root: Path.join(System.tmp_dir!(), "harness-result-store-#{System.unique_integer([:positive])}")}
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
