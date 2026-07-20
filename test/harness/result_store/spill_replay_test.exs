defmodule Harness.ResultStore.SpillReplayTest do
  @moduledoc """
  Facade-level spill-and-replay for settle-time record_run failures (Task 370).

  Uses a controllable fake backend so the recovery path is pinned without needing
  a live schema-drifted Postgres (the undefined_column class is covered in the
  Postgres integration suite).
  """
  # async: false — mutates app env (result_store + dead_letter root + sinks).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Harness.Notification.Event
  alias Harness.ResultStore
  alias Harness.ResultStore.DeadLetter
  alias Harness.ResultStore.Memory
  alias Harness.ResultStore.Replayer
  alias Harness.ResultStoreContract
  alias Harness.Run.LogRecord

  defmodule CaptureSink do
    @moduledoc false
    @behaviour Harness.Notification.Sink

    @spec install() :: :ok
    def install do
      :persistent_term.put({__MODULE__, :events}, [])
      :ok
    end

    @spec events() :: [Event.t()]
    def events, do: :persistent_term.get({__MODULE__, :events}, [])

    @impl true
    @spec notify(Event.t()) :: :ok
    def notify(%Event{} = event) do
      :persistent_term.put({__MODULE__, :events}, [event | events()])
      :ok
    end
  end

  defmodule FlakyBackend do
    @moduledoc false
    @behaviour ResultStore

    alias Harness.Batch.Result, as: BatchResult

    @spec start_link(keyword()) :: {:ok, pid()}
    def start_link(opts \\ []) do
      Agent.start_link(fn ->
        %{
          fail_remaining: Keyword.get(opts, :fail_times, 1),
          notify: Keyword.get(opts, :notify),
          runs: %{}
        }
      end)
    end

    @spec fail_remaining(pid()) :: non_neg_integer()
    def fail_remaining(agent), do: Agent.get(agent, & &1.fail_remaining)

    @impl true
    @spec record_run(LogRecord.t(), keyword()) :: :ok | {:error, term()}
    def record_run(%LogRecord{} = record, opts) do
      agent = Keyword.fetch!(opts, :agent)

      Agent.get_and_update(agent, fn state ->
        if state.fail_remaining > 0 do
          {{:error, :simulated_undefined_column}, %{state | fail_remaining: state.fail_remaining - 1}}
        else
          notify_recorded(state.notify, record.run_id)
          {:ok, %{state | runs: Map.put(state.runs, record.run_id, record)}}
        end
      end)
    end

    @spec notify_recorded(pid() | nil, String.t()) :: :ok
    defp notify_recorded(pid, run_id) when is_pid(pid) do
      send(pid, {:recorded, run_id})
      :ok
    end

    defp notify_recorded(nil, _run_id), do: :ok

    @impl true
    @spec save_batch(BatchResult.t(), keyword()) :: :ok
    def save_batch(%BatchResult{}, _opts), do: :ok

    @impl true
    @spec load_batch(String.t(), keyword()) :: {:error, :not_found}
    def load_batch(_id, _opts), do: {:error, :not_found}

    @impl true
    @spec list_run_records(ResultStore.filters(), keyword()) :: {:ok, [LogRecord.t()]}
    def list_run_records(filters, opts) do
      runs = Agent.get(Keyword.fetch!(opts, :agent), & &1.runs)
      records = Map.values(runs)

      filtered =
        case Keyword.get(filters, :run_id) do
          nil -> records
          run_id -> Enum.filter(records, &(&1.run_id == run_id))
        end

      {:ok, filtered}
    end

    @impl true
    @spec delete_run(String.t(), keyword()) :: :ok
    def delete_run(run_id, opts) do
      Agent.update(Keyword.fetch!(opts, :agent), fn state ->
        %{state | runs: Map.delete(state.runs, run_id)}
      end)
    end

    @impl true
    @spec mark_landed(String.t(), String.t(), keyword()) :: :ok | {:error, :run_record_not_found}
    def mark_landed(run_id, sha, opts) do
      agent = Keyword.fetch!(opts, :agent)

      Agent.get_and_update(agent, fn state ->
        case Map.fetch(state.runs, run_id) do
          {:ok, record} ->
            {:ok, %{state | runs: Map.put(state.runs, run_id, %{record | landed_sha: sha})}}

          :error ->
            {{:error, :run_record_not_found}, state}
        end
      end)
    end

    @impl true
    @spec aggregate_by_agent(keyword(), keyword()) :: {:ok, map()}
    def aggregate_by_agent(_q, _opts), do: {:ok, %{}}

    @impl true
    @spec aggregate_reviewer_reliability(keyword(), keyword()) :: {:ok, map()}
    def aggregate_reviewer_reliability(_q, _opts), do: {:ok, %{}}

    @impl true
    @spec aggregate_by_facet(keyword(), keyword()) :: {:ok, list()}
    def aggregate_by_facet(_q, _opts), do: {:ok, []}
  end

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "dead_letter")
    prev_dl = Application.get_env(:harness, :result_store_dead_letter)
    prev_sinks = Application.get_env(:harness, :notification_sinks)

    Application.put_env(:harness, :result_store_dead_letter, root: root)
    CaptureSink.install()
    Application.put_env(:harness, :notification_sinks, [CaptureSink])

    on_exit(fn ->
      restore(:result_store_dead_letter, prev_dl)
      restore(:notification_sinks, prev_sinks)
    end)

    :ok
  end

  describe "record_run failure → spill + loud notify → replay" do
    test "insert failure spills the payload and recovers after the backend works again" do
      {:ok, agent} = FlakyBackend.start_link(fail_times: 1)
      store = {FlakyBackend, agent: agent}
      record = ResultStoreContract.log_record(run_id: "run-recover-1", task_id: "370", verdict: :approve)

      log =
        capture_log(fn ->
          assert {:error, :simulated_undefined_column} = ResultStore.record_run(record, store)
        end)

      assert log =~ "FAILED to persist run record run-recover-1"
      assert DeadLetter.exists?("run-recover-1")
      assert {:ok, []} = ResultStore.list_run_records(store, run_id: "run-recover-1")

      # Loud operator surface — notification sink, not only a log line.
      assert Enum.any?(CaptureSink.events(), fn
               %Event{type: :persist_failed, run_id: "run-recover-1"} -> true
               _ -> false
             end)

      # Backend now accepts inserts (fail_remaining exhausted). Replay restores the row.
      assert {:ok, %{replayed: 1, remaining: 0}} = ResultStore.replay_spilled(store)
      refute DeadLetter.exists?("run-recover-1")

      assert {:ok, [%LogRecord{run_id: "run-recover-1", verdict: :approve}]} =
               ResultStore.list_run_records(store, run_id: "run-recover-1")
    end

    test "a successful later record_run opportunistically replays prior spills" do
      {:ok, agent} = FlakyBackend.start_link(fail_times: 1)
      store = {FlakyBackend, agent: agent}
      first = ResultStoreContract.log_record(run_id: "run-opp-1", task_id: "1")
      second = ResultStoreContract.log_record(run_id: "run-opp-2", task_id: "2")

      capture_log(fn ->
        assert {:error, :simulated_undefined_column} = ResultStore.record_run(first, store)
      end)

      assert DeadLetter.exists?("run-opp-1")

      # Second write succeeds and triggers facade replay of the spill.
      assert :ok = ResultStore.record_run(second, store)
      refute DeadLetter.exists?("run-opp-1")
      assert {:ok, recovered} = ResultStore.list_run_records(store, run_id: "run-opp-1")
      assert [%{run_id: "run-opp-1"}] = recovered
      assert {:ok, [%{run_id: "run-opp-2"}]} = ResultStore.list_run_records(store, run_id: "run-opp-2")
    end

    test "periodic replayer recovers a spill without a restart or later settle" do
      {:ok, agent} = FlakyBackend.start_link(fail_times: 1, notify: self())
      store = {FlakyBackend, agent: agent}
      record = ResultStoreContract.log_record(run_id: "run-periodic-1", task_id: "370")

      capture_log(fn ->
        assert {:error, :simulated_undefined_column} = ResultStore.record_run(record, store)
      end)

      assert DeadLetter.exists?(record.run_id)

      replayer = start_supervised!({Replayer, interval_ms: 10, name: :task_370_replayer, store: store})

      assert_receive {:recorded, "run-periodic-1"}, 500
      assert %{store: ^store} = :sys.get_state(replayer)
      refute DeadLetter.exists?(record.run_id)
      assert {:ok, [%{run_id: "run-periodic-1"}]} = ResultStore.list_run_records(store, run_id: record.run_id)
    end

    test "mark_landed on a missing row patches the spill's landed_sha" do
      {:ok, agent} = FlakyBackend.start_link(fail_times: 1)
      store = {FlakyBackend, agent: agent}
      record = ResultStoreContract.log_record(run_id: "run-land-patch", task_id: "9")

      capture_log(fn ->
        assert {:error, :simulated_undefined_column} = ResultStore.record_run(record, store)
      end)

      capture_log(fn ->
        assert {:error, :run_record_not_found} = ResultStore.mark_landed("run-land-patch", "landedsha1", store)
      end)

      assert {:ok, %{record: %{landed_sha: "landedsha1"}}} = DeadLetter.load("run-land-patch")

      assert {:ok, %{replayed: 1, remaining: 0}} = ResultStore.replay_spilled(store)

      assert {:ok, [%{landed_sha: "landedsha1"}]} =
               ResultStore.list_run_records(store, run_id: "run-land-patch")
    end
  end

  describe "Memory mark_landed not_found" do
    test "missing run_id returns {:error, :run_record_not_found}" do
      store = {Memory, scope: :spill_replay_mem}
      Memory.reset(scope: :spill_replay_mem)

      assert {:error, :run_record_not_found} =
               ResultStore.mark_landed("never-recorded", "abc", store)
    end
  end

  @spec restore(atom(), term()) :: :ok
  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)
end
