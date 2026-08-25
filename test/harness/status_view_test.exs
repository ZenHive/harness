defmodule Harness.StatusViewTest do
  # async: false because tests reset AgentRegistry and inspect shared run/result state.
  use ExUnit.Case, async: false

  alias Harness.AgentRegistry
  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.ResultStore
  alias Harness.Roadmap.Item
  alias Harness.Run
  alias Harness.Run.LogRecord
  alias Harness.Run.Status
  alias Harness.Run.Supervisor, as: RunSupervisor
  alias Harness.StatusView
  alias Harness.Test.IdentityFakeAdapter, as: FakeAdapter

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
    assert StatusView.classify(%Status{state: :recovering, run_id: "r", task_id: "1"}) == :repairing
    assert StatusView.classify(%Status{state: :reviewing, run_id: "r", task_id: "1"}) == :repairing
    assert StatusView.classify(%Status{state: :done, run_id: "r", task_id: "1"}) == :green
    assert StatusView.classify(%Status{state: :failed, run_id: "r", task_id: "1"}) == :red
  end

  test "classify/1 covers every lifecycle state in the Status typespec" do
    # Regression guard for Task 148: a Run state added without a classify/1
    # clause crashes every concurrent snapshot/0 caller, poisoning the
    # snapshot for all dispatched runs.
    in_flight_states = [:dispatched, :running, :committing, :held]

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
          status: %Status{run_id: "run-b", task_id: "2", state: :reviewing},
          bucket: :repairing,
          detail: nil
        },
        %{status: %Status{run_id: "run-c", task_id: "3", state: :done}, bucket: :green, detail: nil},
        %{
          status: %Status{run_id: "run-d", task_id: "4", state: :failed, reason: :cancelled},
          bucket: :red,
          detail: "cancelled"
        }
      ],
      unavailable_agents: [{FakeAdapter, {:review_stuck, "task-7", "implementer hit a usage limit"}}],
      cron_polling: :disabled
    }

    output = StatusView.render(snapshot)

    assert output =~ "IN FLIGHT (1)"
    assert output =~ "task 1  run-a  running"
    assert output =~ "REPAIRING (1)"
    assert output =~ "task 2  run-b  reviewing"
    assert output =~ "GREEN (1)"
    assert output =~ "task 3  run-c  done"
    assert output =~ "RED (1)"
    assert output =~ "task 4  run-d  failed  cancelled"
    assert output =~ "UNAVAILABLE AGENTS (1)"
    assert output =~ "FakeAdapter  review stuck on task-7: implementer hit a usage limit"
  end

  test "run_entry_for/1 renders an :unavailable model rejection without crashing" do
    status = %Status{
      run_id: "run-u",
      task_id: "9",
      state: :failed,
      reason: {:unavailable, :cursor, "composer-2.5-fast", available: []}
    }

    entry = StatusView.run_entry_for(status)

    assert entry.bucket == :red
    assert entry.detail == "Configured model is unavailable"
  end

  test "run_entry_for/1 lists available ids when the rejected model has alternatives" do
    status = %Status{
      run_id: "run-u2",
      task_id: "10",
      state: :failed,
      reason: {:unavailable, :cursor, "composer-2.5-fast", available: ["composer-2.5", "gemini-3.1-pro"]}
    }

    assert StatusView.run_entry_for(status).detail ==
             "Configured model is unavailable"
  end

  test "run_entry_for/1 renders a model-required reviewer failure" do
    status = %Status{run_id: "run-x", task_id: "11", state: :failed, reason: {:model_required, :codex}}

    assert StatusView.run_entry_for(status).detail == "Reviewer has no configured model"
  end

  test "run_entry_for/1 falls back to inspect for an unrecognized reason shape" do
    status = %Status{run_id: "run-x", task_id: "11", state: :failed, reason: {:weird, 1, 2, 3, 4}}

    assert StatusView.run_entry_for(status).detail == "{:weird, 1, 2, 3, 4}"
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
      for run_id <- ~w(sv-hist-001 sv-hist-002 sv-hist-003) do
        fields =
          case run_id do
            "sv-hist-002" ->
              [state: :failed, reason: {:review_rejected, "nothing to salvage"}, verdict: :reject]

            _ ->
              [state: :done, verdict: :approve]
          end

        :ok = ResultStore.record_run(record(run_id, fields))
      end

      mine = Enum.filter(StatusView.snapshot().history, &(&1.status.run_id in ~w(sv-hist-001 sv-hist-002 sv-hist-003)))

      # Store orders by newest insert first.
      assert Enum.map(mine, & &1.status.run_id) == ~w(sv-hist-003 sv-hist-002 sv-hist-001)

      buckets = Map.new(mine, &{&1.status.run_id, &1.bucket})
      assert buckets["sv-hist-003"] == :green
      assert buckets["sv-hist-002"] == :red
    end

    test "excludes a run that is still live (the live entry wins)" do
      run_id = start_run(adapter_opts: [command: :sleep], terminal_linger: 5_000)
      assert await_running(run_id)

      :ok = ResultStore.record_run(record(run_id, state: :done, verdict: :approve))

      snapshot = StatusView.snapshot()

      assert Enum.any?(snapshot.runs, &(&1.status.run_id == run_id))
      refute Enum.any?(snapshot.history, &(&1.status.run_id == run_id))

      assert :ok = Run.cancel(run_id)
    end

    test "skips a persisted record with a non-terminal state instead of crashing the snapshot" do
      :ok = ResultStore.record_run(record("sv-hist-good", state: :done, verdict: :approve))
      :ok = ResultStore.record_run(record("sv-hist-poison", state: :reviewing))

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
        StatusView.run_entry_for(%Status{run_id: "e-2", task_id: "1", state: :failed, reason: :cancelled})

      assert %{bucket: :red, detail: "Run was cancelled"} = failed
    end
  end

  describe "describe_reason/1 and failure_copy/1" do
    test "maps known reason heads to a fixed operator headline" do
      assert StatusView.describe_reason({:review_stuck, "no artifact"}) == "Reviewer produced no verdict"
      assert StatusView.describe_reason({:review_rejected, "nothing to salvage"}) == "Reviewer rejected the work"
      assert StatusView.describe_reason(:cancelled) == "Run was cancelled"
      assert StatusView.describe_reason({:model_required, :codex}) == "Reviewer has no configured model"
    end

    test "falls through to inspect for an unmapped reason shape" do
      assert StatusView.describe_reason({:weird, 1, 2, 3, 4}) == "{:weird, 1, 2, 3, 4}"
    end

    test "failure_copy/1 names the recovery primitive and reports a retained branch" do
      status = %Status{
        run_id: "run-keep",
        task_id: "1",
        state: :failed,
        reason: {:review_stuck, "Reviewer wrote no .harness/review.json verdict artifact."},
        state_entered_at: %{committing: ~U[2026-08-25 10:00:00Z], reviewing: ~U[2026-08-25 10:01:00Z]}
      }

      copy = StatusView.failure_copy(status)

      assert copy.headline == "Reviewer produced no verdict"
      assert copy.headline == StatusView.describe_reason(status.reason)
      assert copy.consequence == "The implementer's commits on harness/run-keep are retained."
      assert copy.recovery == "dispatch-rereview"
      assert copy.raw == inspect(status.reason)
    end

    test "failure_copy/1 reports when no implementer commits were retained" do
      status = %Status{
        run_id: "run-empty",
        task_id: "1",
        state: :failed,
        reason: {:worktree_failed, :boom}
      }

      copy = StatusView.failure_copy(status)

      assert copy.headline == "Worktree could not be created"
      assert copy.consequence == "No implementer commits were retained on harness/run-empty."
      assert copy.recovery == "cancel"
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

    test "skips a registered run whose status call does not reply promptly" do
      run_id = "sv-stuck-status"
      start_supervised!({__MODULE__.SlowStatusRun, run_id})

      task = Task.async(fn -> :timer.tc(StatusView, :live_runs, []) end)

      assert {_elapsed_us, entries} = yield_or_flunk(task)
      refute Enum.any?(entries, &(&1.status.run_id == run_id))
    end

    test "snapshot omits a slow run status read within the bounded timeout" do
      run_id = "sv-stuck-snapshot"
      start_supervised!({__MODULE__.SlowStatusRun, run_id})

      task = Task.async(fn -> :timer.tc(StatusView, :snapshot, []) end)

      assert {elapsed_us, snapshot} = yield_or_flunk(task)
      assert elapsed_us < 400_000
      refute Enum.any?(snapshot.runs, &(&1.status.run_id == run_id))
    end
  end

  describe "Run.status/2" do
    test "returns a timeout error when a registered run does not reply promptly" do
      run_id = "sv-stuck-run-status"
      start_supervised!({__MODULE__.SlowStatusRun, run_id})

      assert {:error, :timeout} = Run.status(run_id, 10)
    end
  end

  defp record(run_id, opts) do
    %LogRecord{
      batch_id: "batch-#{run_id}",
      run_id: run_id,
      task_id: Keyword.get(opts, :task_id, "1"),
      agent: Keyword.get(opts, :agent),
      adapter: FakeAdapter,
      state: Keyword.get(opts, :state, :done),
      reason: Keyword.get(opts, :reason, :approved),
      verdict: Keyword.get(opts, :verdict, :approve),
      duration_ms: 1_000,
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
          reviewer: FakeAdapter,
          reviewer_adapter_opts: [command: {:review, "approve"}],
          total_timeout: 30_000,
          idle_timeout: 10_000,
          lifetime_timeout: 30_000,
          terminal_linger: 100
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

  defp yield_or_flunk(task) do
    case Task.yield(task, 500) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        flunk("live_runs/0 blocked on a non-responsive run status call")
    end
  end

  defmodule SlowStatusRun do
    @moduledoc false
    @behaviour :gen_statem

    @spec child_spec(String.t()) :: Supervisor.child_spec()
    def child_spec(run_id) do
      %{id: {__MODULE__, run_id}, start: {__MODULE__, :start_link, [run_id]}}
    end

    @spec start_link(String.t()) :: :gen_statem.start_ret()
    def start_link(run_id) do
      :gen_statem.start_link({:via, Registry, {Harness.Run.Registry, run_id}}, __MODULE__, nil, [])
    end

    @impl :gen_statem
    @spec callback_mode() :: :handle_event_function
    def callback_mode, do: :handle_event_function

    @impl :gen_statem
    @spec init(nil) :: {:ok, :running, nil}
    def init(nil), do: {:ok, :running, nil}

    @impl :gen_statem
    @spec handle_event(:gen_statem.event_type(), term(), :running, nil) :: :gen_statem.event_handler_result(:running)
    def handle_event({:call, _from}, :status, :running, nil), do: {:keep_state_and_data, []}
  end
end
