defmodule Harness.BatchTest do
  use ExUnit.Case, async: false

  alias Harness.Batch
  alias Harness.Batch.Result, as: BatchResult
  alias Harness.FakeAdapter
  alias Harness.GitFixture
  alias Harness.Roadmap.Item
  alias Harness.Run
  alias Harness.Run.Result
  alias Harness.Verification.Check

  @eventually_tries 150
  @eventually_delay_ms 20
  @run_timeout_ms 30_000
  @terminal_linger_ms 100

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
