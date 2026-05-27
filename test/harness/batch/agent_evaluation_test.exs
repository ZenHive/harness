defmodule Harness.Batch.AgentEvaluationTest do
  use ExUnit.Case, async: false

  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.OSProcess
  alias Harness.AgentAdapter.Run, as: AgentRun
  alias Harness.AgentRegistry
  alias Harness.Batch
  alias Harness.Batch.AgentEvaluation
  alias Harness.Batch.AgentEvaluation.Comparison
  alias Harness.Batch.AgentEvaluation.Entry
  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.Roadmap.Item
  alias Harness.Verification.Check

  @run_timeout_ms 30_000
  @terminal_linger_ms 100

  defmodule GreenAdapter do
    @moduledoc false
    @behaviour Harness.AgentAdapter

    @impl Harness.AgentAdapter
    def capabilities, do: %Capabilities{session_resume: true}

    @impl Harness.AgentAdapter
    def rule_channel, do: :none

    @impl Harness.AgentAdapter
    def build_command(%Invocation{}) do
      {:ok, {"/bin/sh", ["-c", "echo agent-output > agent_output.txt; echo pass > status.txt"], []}}
    end

    @impl Harness.AgentAdapter
    def classify_message({port, {:data, data}}, %AgentRun{port: port} = run), do: {:output, data, run}

    def classify_message({port, {:exit_status, status}}, %AgentRun{port: port} = run), do: {:terminated, run, status}

    def classify_message(_message, _run), do: :ignore

    @impl Harness.AgentAdapter
    def terminate(%AgentRun{} = run), do: OSProcess.kill(run)
  end

  defmodule RedAdapter do
    @moduledoc false
    @behaviour Harness.AgentAdapter

    @impl Harness.AgentAdapter
    def capabilities, do: %Capabilities{session_resume: true}

    @impl Harness.AgentAdapter
    def rule_channel, do: :none

    @impl Harness.AgentAdapter
    def build_command(%Invocation{}) do
      {:ok, {"/bin/sh", ["-c", "echo agent-output > agent_output.txt; echo fail > status.txt"], []}}
    end

    @impl Harness.AgentAdapter
    def classify_message({port, {:data, data}}, %AgentRun{port: port} = run), do: {:output, data, run}

    def classify_message({port, {:exit_status, status}}, %AgentRun{port: port} = run), do: {:terminated, run, status}

    def classify_message(_message, _run), do: :ignore

    @impl Harness.AgentAdapter
    def terminate(%AgentRun{} = run), do: OSProcess.kill(run)
  end

  defmodule CrashAdapter do
    @moduledoc false
    @behaviour Harness.AgentAdapter

    @impl Harness.AgentAdapter
    def capabilities, do: %Capabilities{session_resume: true}

    @impl Harness.AgentAdapter
    def rule_channel, do: :none

    @impl Harness.AgentAdapter
    def build_command(%Invocation{}), do: {:ok, {"definitely-not-a-real-binary-xyz", [], []}}

    @impl Harness.AgentAdapter
    def classify_message({port, {:data, data}}, %AgentRun{port: port} = run), do: {:output, data, run}

    def classify_message({port, {:exit_status, status}}, %AgentRun{port: port} = run), do: {:terminated, run, status}

    def classify_message(_message, _run), do: :ignore

    @impl Harness.AgentAdapter
    def terminate(%AgentRun{} = run), do: OSProcess.kill(run)
  end

  setup do
    AgentRegistry.reset()
    ProjectRegistry.reset()
    :ok
  end

  test "compares one task across N adapters with side-by-side metrics" do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    store = file_store()
    item = item("ab-task")
    id = batch_id()

    assert {:ok, %Comparison{batch_id: ^id, task_id: "ab-task", total: 2, entries: entries}} =
             AgentEvaluation.compare(
               item,
               ProjectFixture.from_repo(repo),
               [GreenAdapter, RedAdapter],
               eval_opts(base, batch_id: id, result_store: store, max_concurrency: 2)
             )

    assert [%Entry{adapter: GreenAdapter}, %Entry{adapter: RedAdapter}] = entries

    assert %Entry{
             adapter: GreenAdapter,
             state: :done,
             reason: :passed,
             verdict: :pass,
             repair_attempts: 0,
             first_attempt_failed_check_count: 0,
             agent_diff_size: diff_size
           } = Enum.at(entries, 0)

    assert is_integer(diff_size) and diff_size > 0
    assert Enum.at(entries, 0).duration_ms >= 0

    assert %Entry{
             adapter: RedAdapter,
             state: :failed,
             reason: :verification_red,
             verdict: :fail,
             repair_attempts: 0,
             first_attempt_failed_check_count: 1,
             agent_diff_size: red_diff
           } = Enum.at(entries, 1)

    assert is_integer(red_diff) and red_diff > 0
  end

  test "tolerates partial failure without aborting the comparison" do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    item = item("partial")

    assert {:ok, %Comparison{entries: entries}} =
             AgentEvaluation.compare(
               item,
               ProjectFixture.from_repo(repo),
               [GreenAdapter, CrashAdapter, RedAdapter],
               eval_opts(base, max_concurrency: 3, result_store: false)
             )

    assert length(entries) == 3

    by_adapter = Map.new(entries, &{&1.adapter, &1})
    assert by_adapter[GreenAdapter].state == :done
    assert by_adapter[CrashAdapter].state == :failed
    assert by_adapter[RedAdapter].state == :failed
    assert by_adapter[RedAdapter].reason == :verification_red
  end

  test "run_pinned keeps adapters on their own slots without cross fail-over" do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    item = item("pinned")

    assert {:ok, batch} =
             Batch.run_pinned(
               [{item, GreenAdapter}, {item, RedAdapter}],
               ProjectFixture.from_repo(repo),
               eval_opts(base, max_concurrency: 2)
             )

    assert length(batch.results) == 2
    assert Enum.at(batch.results, 0).state == :done
    assert Enum.at(batch.results, 1).state == :failed
  end

  test "REGRESSION (Task 68): from_batch/3 raises on adapter/results length mismatch" do
    batch = %Harness.Batch.Result{
      batch_id: "mismatch-test",
      total: 2,
      max_concurrency: 2,
      results: [
        %Harness.Run.Result{
          run_id: "r1",
          task_id: "t",
          state: :done,
          reason: :passed
        }
      ],
      events: []
    }

    assert_raise ArgumentError, ~r/equal length/, fn ->
      AgentEvaluation.from_batch(batch, [GreenAdapter, RedAdapter], false)
    end
  end

  test "from_batch rebuilds a comparison from a persisted batch" do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    store = file_store()
    batch_id = batch_id()
    item = item("reload")

    assert {:ok, batch} =
             Batch.run_pinned(
               [{item, GreenAdapter}, {item, GreenAdapter}],
               ProjectFixture.from_repo(repo),
               eval_opts(base,
                 batch_id: batch_id,
                 result_store: store
               )
             )

    comparison = AgentEvaluation.from_batch(batch, [GreenAdapter, GreenAdapter], store)

    assert comparison.batch_id == batch_id
    assert comparison.task_id == "reload"
    assert length(comparison.entries) == 2
    assert Enum.all?(comparison.entries, &(&1.state == :done and &1.verdict == :pass))
  end

  defp eval_opts(base, overrides) do
    Keyword.merge(
      [
        base_dir: base,
        checks: [check("status", "grep", ["pass", "status.txt"])],
        total_timeout: @run_timeout_ms,
        idle_timeout: @run_timeout_ms,
        lifetime_timeout: @run_timeout_ms,
        verification_timeout: @run_timeout_ms,
        terminal_linger: @terminal_linger_ms,
        max_repair_attempts: 0
      ],
      overrides
    )
  end

  defp item(id) do
    %Item{id: id, title: "Task #{id}", prompt: "do task #{id}", agent: :claude}
  end

  defp check(name, command, args), do: %Check{name: name, command: command, args: args}

  defp batch_id, do: "batch-#{System.unique_integer([:positive])}"

  defp file_store do
    {Harness.ResultStore.File,
     root:
       Path.join(
         System.tmp_dir!(),
         "harness-eval-store-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
       )}
  end
end
