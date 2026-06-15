defmodule Harness.Run.CodeReloadCrashTest do
  use Harness.RunCase, async: true

  alias Harness.ResultStore

  describe "code-reload crash hardening (Task 299)" do
    test "REGRESSION: abnormal terminate during :reviewing persists a crash record and notifies subscriber" do
      parent = self()
      store = file_store()
      Application.put_env(:harness, :result_store, store)
      on_exit(fn -> Application.delete_env(:harness, :result_store) end)

      :ok = RunFeed.subscribe()

      {run_id, pid} =
        start(
          subscriber: parent,
          result_store: store,
          reviewer_adapter_opts: [command: :sleep],
          reviewing_idle_timeout: 30_000,
          lifetime_timeout: 60_000,
          terminal_linger: 100
        )

      assert_receive {:harness_run_update, %Status{run_id: ^run_id, state: :reviewing}}, 10_000

      undef_reason = {:undef, [{Harness.Run, :reviewing, [:info, {:transcript_chunk, "x"}, %{}]}]}
      assert :ok = :gen_statem.stop(pid, undef_reason, 5_000)

      assert_receive {:harness_run, ^run_id, %Result{state: :failed, reason: crash_reason}}, 5_000
      assert crash_reason == {:run_crashed, {:code_reload, :reviewing, undef_reason}}

      assert {:ok, [record]} = ResultStore.list_run_records(store, run_id: run_id)
      assert record.state == :failed
      assert record.reason == crash_reason

      assert_receive {:harness_run_settled, %Status{run_id: ^run_id, state: :failed}}
    end

    test "transcript_chunk during :reviewing on a loaded module does not crash (genuine-gap negative)" do
      :ok = RunFeed.subscribe()

      {run_id, pid} =
        start(
          reviewer_adapter_opts: [command: :sleep],
          reviewing_idle_timeout: 30_000,
          lifetime_timeout: 60_000,
          terminal_linger: 100
        )

      assert_receive {:harness_run_update, %Status{run_id: ^run_id, state: :reviewing}}, 10_000

      send(pid, {:transcript_chunk, ~s({"type":"assistant","message":"noise"})})
      assert {:ok, %Status{state: :reviewing}} = Run.status(run_id)

      assert :ok = Run.cancel(run_id)
      await_result(run_id, pid)
    end
  end
end
