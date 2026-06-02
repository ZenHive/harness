defmodule Harness.StatusViewTest do
  use ExUnit.Case, async: false

  alias Harness.AgentRegistry
  alias Harness.FakeAdapter
  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.ResultStore
  alias Harness.Roadmap.Item
  alias Harness.Run
  alias Harness.Run.LogRecord
  alias Harness.Run.Status
  alias Harness.Run.Supervisor, as: RunSupervisor
  alias Harness.StatusView

  setup do
    AgentRegistry.reset()
    :ok
  end

  test "render/1 shows an empty fleet message when nothing is registered" do
    output = StatusView.render(%{runs: [], unavailable_agents: [], cron_polling: :disabled})

    assert output =~ "Harness fleet status"
    assert output =~ "Cron polling: disabled"
    assert output =~ "(no runs in flight or lingering)"
  end

  test "render/1 shows the next scheduled cron tick in the header" do
    output =
      StatusView.render(%{
        runs: [],
        unavailable_agents: [],
        cron_polling: {:enabled, "0 */2 * * *", ~U[2026-05-27 02:00:00Z]}
      })

    assert output =~ "Cron polling: next tick 2026-05-27 02:00:00Z (0 */2 * * *)"
  end

  test "classify/1 maps lifecycle states into the four buckets" do
    assert StatusView.classify(%Status{state: :running, run_id: "r", task_id: "1"}) == :in_flight
    assert StatusView.classify(%Status{state: :reviewing, run_id: "r", task_id: "1"}) == :repairing
    assert StatusView.classify(%Status{state: :done, run_id: "r", task_id: "1"}) == :green
    assert StatusView.classify(%Status{state: :failed, run_id: "r", task_id: "1"}) == :red
  end

  test "classify/1 covers every lifecycle state in the Status typespec" do
    # Regression guard for Task 148: a Run state added without a classify/1
    # clause crashes every concurrent snapshot/0 caller, poisoning
    # verification for all dispatched runs.
    in_flight_states = [:dispatched, :running, :committing, :verifying, :held]

    for state <- in_flight_states do
      assert StatusView.classify(%Status{state: state, run_id: "r", task_id: "1"}) == :in_flight
    end

    assert StatusView.classify(%Status{state: :reviewing, run_id: "r", task_id: "1"}) == :repairing
    assert StatusView.classify(%Status{state: :done, run_id: "r", task_id: "1"}) == :green
    assert StatusView.classify(%Status{state: :failed, run_id: "r", task_id: "1"}) == :red
  end

  test "render/1 groups runs into the four buckets with failure and availability detail" do
    snapshot = %{
      runs: [
        %{status: %Status{run_id: "run-a", task_id: "1", state: :running}, bucket: :in_flight, detail: nil},
        %{
          status: %Status{run_id: "run-b", task_id: "2", state: :reviewing, review_iterations: 1},
          bucket: :repairing,
          detail: "review iteration 1"
        },
        %{status: %Status{run_id: "run-c", task_id: "3", state: :done}, bucket: :green, detail: nil},
        %{
          status: %Status{run_id: "run-d", task_id: "4", state: :failed, reason: :verification_red},
          bucket: :red,
          detail: "verification_red"
        }
      ],
      unavailable_agents: [{FakeAdapter, {:review_stuck, "task-7", "implementer hit a usage limit"}}],
      cron_polling: :disabled
    }

    output = StatusView.render(snapshot)

    assert output =~ "IN FLIGHT (1)"
    assert output =~ "task 1  run-a  running"
    assert output =~ "REPAIRING (1)"
    assert output =~ "task 2  run-b  reviewing  review iteration 1"
    assert output =~ "GREEN (1)"
    assert output =~ "task 3  run-c  done"
    assert output =~ "RED (1)"
    assert output =~ "task 4  run-d  failed  verification_red"
    assert output =~ "UNAVAILABLE AGENTS (1)"
    assert output =~ "FakeAdapter  review stuck on task-7: implementer hit a usage limit"
  end

  test "snapshot/1 collects live registered runs" do
    run_id = start_run(adapter_opts: [command: :sleep], terminal_linger: 5_000)

    assert await_running(run_id)

    output = StatusView.render(StatusView.snapshot())

    assert output =~ "task 8  #{run_id}  running"

    assert :ok = Run.cancel(run_id)
  end

  describe "snapshot/0 history (persisted settled runs)" do
    test "surfaces persisted records newest-first with the right buckets" do
      base = System.os_time(:second)

      for {run_id, offset} <- Enum.with_index(~w(sv-hist-001 sv-hist-002 sv-hist-003)) do
        fields =
          case run_id do
            "sv-hist-002" ->
              [state: :failed, reason: :verification_red, verdict: :fail]

            _ ->
              [state: :done, verdict: :pass]
          end

        :ok = ResultStore.record_run(record(run_id, fields))
        touch_run_file(run_id, base + offset)
      end

      mine = Enum.filter(StatusView.snapshot().history, &(&1.status.run_id in ~w(sv-hist-001 sv-hist-002 sv-hist-003)))

      # Store orders by inserted_at / file mtime, newest first.
      assert Enum.map(mine, & &1.status.run_id) == ~w(sv-hist-003 sv-hist-002 sv-hist-001)

      buckets = Map.new(mine, &{&1.status.run_id, &1.bucket})
      assert buckets["sv-hist-003"] == :green
      assert buckets["sv-hist-002"] == :red
    end

    test "excludes a run that is still live (the live entry wins)" do
      run_id = start_run(adapter_opts: [command: :sleep], terminal_linger: 5_000)
      assert await_running(run_id)

      :ok = ResultStore.record_run(record(run_id, state: :done, verdict: :pass))

      snapshot = StatusView.snapshot()

      assert Enum.any?(snapshot.runs, &(&1.status.run_id == run_id))
      refute Enum.any?(snapshot.history, &(&1.status.run_id == run_id))

      assert :ok = Run.cancel(run_id)
    end

    test "skips a persisted record with a non-terminal state instead of crashing the snapshot" do
      :ok = ResultStore.record_run(record("sv-hist-good", state: :done, verdict: :pass))
      :ok = ResultStore.record_run(record("sv-hist-poison", state: :passed))

      {history, log} = ExUnit.CaptureLog.with_log(fn -> StatusView.snapshot().history end)
      ids = Enum.map(history, & &1.status.run_id)

      assert "sv-hist-good" in ids
      refute "sv-hist-poison" in ids
      assert log =~ "skipping history record sv-hist-poison"
    end

    test "render/1 ignores history so `mix harness.status` stays current-fleet" do
      history = [
        %{status: %Status{run_id: "sv-hist-x", task_id: "hist-task", state: :done}, bucket: :green, detail: nil}
      ]

      output = StatusView.render(%{runs: [], unavailable_agents: [], history: history, cron_polling: :disabled})

      assert output =~ "(no runs in flight or lingering)"
      refute output =~ "hist-task"
    end
  end

  describe "run_entry_for/1" do
    test "wraps a status into a classified, detailed entry" do
      entry = StatusView.run_entry_for(%Status{run_id: "e-1", task_id: "1", state: :running})
      assert %{status: %Status{run_id: "e-1"}, bucket: :in_flight, detail: nil} = entry

      failed =
        StatusView.run_entry_for(%Status{run_id: "e-2", task_id: "1", state: :failed, reason: :verification_red})

      assert %{bucket: :red, detail: "verification_red"} = failed
    end
  end

  describe "live_runs/0" do
    test "collects in-memory live runs as classified entries (no history/disk)" do
      run_id = start_run(adapter_opts: [command: :sleep], terminal_linger: 5_000)
      assert await_running(run_id)

      entries = StatusView.live_runs()
      mine = Enum.find(entries, &(&1.status.run_id == run_id))

      assert %{status: %Status{run_id: ^run_id, state: :running}, bucket: :in_flight} = mine

      assert :ok = Run.cancel(run_id)
    end
  end

  defp touch_run_file(run_id, mtime) do
    case Application.get_env(:harness, :result_store) do
      {Harness.ResultStore.File, opts} when is_list(opts) ->
        root = opts |> Keyword.get(:root, "~/.harness/results") |> Path.expand()
        path = Path.join([root, "runs", Base.url_encode64(run_id, padding: false) <> ".term"])
        File.touch!(path, mtime)

      _ ->
        :ok
    end
  end

  defp record(run_id, opts) do
    reason = Keyword.get(opts, :reason, :passed)

    %LogRecord{
      batch_id: "batch-#{run_id}",
      run_id: run_id,
      task_id: Keyword.get(opts, :task_id, "1"),
      agent: Keyword.get(opts, :agent),
      adapter: FakeAdapter,
      state: Keyword.get(opts, :state, :done),
      reason: reason,
      verdict: Keyword.get(opts, :verdict, :pass),
      duration_ms: 1_000,
      review_iterations: 0,
      first_attempt_failed_check_count: 0,
      failure_cause: %{reason: reason, failed_checks: []},
      agent_outcome_kind: Keyword.get(opts, :agent_outcome_kind),
      agent_output: Keyword.get(opts, :agent_output, "")
    }
  end

  defp start_run(overrides) do
    {item_id, overrides} = Keyword.pop(overrides, :item_id, "8")
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()

    project = ProjectFixture.from_repo(repo)

    opts =
      Keyword.merge(
        [
          base_dir: base,
          total_timeout: 30_000,
          idle_timeout: 10_000,
          lifetime_timeout: 30_000,
          verification_timeout: 10_000,
          terminal_linger: 100,
          max_review_iterations: 0
        ],
        overrides
      )

    {:ok, run_id, _pid} = RunSupervisor.start_run(item(item_id), project, FakeAdapter, opts)
    run_id
  end

  defp item(id) do
    %Item{id: id, title: "Human status view", prompt: "do the thing", agent: :claude}
  end

  defp await_running(run_id, tries \\ 150)

  defp await_running(_run_id, 0), do: flunk("run never reached :running")

  defp await_running(run_id, tries) do
    case Run.status(run_id) do
      {:ok, %Status{state: :running}} ->
        :ok

      _ ->
        Process.sleep(20)
        await_running(run_id, tries - 1)
    end
  end
end
