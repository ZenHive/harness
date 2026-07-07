defmodule Harness.Run.ReflexFloorTest do
  use Harness.RunCase, async: false

  describe "reflex floor" do
    @tag :capture_log
    test "progress stall settles failed and routes a blocked event at the cap" do
      Application.put_env(:harness, :notification_sinks, [CaptureSink])
      Application.put_env(:harness, :test_capture_pid, self())

      on_exit(fn ->
        Application.delete_env(:harness, :notification_sinks)
        Application.delete_env(:harness, :test_capture_pid)
      end)

      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()
      project = ProjectFixture.from_repo(repo, name: "reflex-#{System.unique_integer([:positive])}")

      :ok = ProjectRegistry.register(project)
      on_exit(fn -> ProjectRegistry.unregister(project.name) end)

      opts =
        base
        |> default_opts()
        |> Keyword.merge(adapter_opts: [command: :flood], progress_timeout: 250, land_attempt: 2)

      {:ok, run_id, pid} = Run.Supervisor.start_run(item(), project, FakeAdapter, opts)

      assert %Result{
               state: :failed,
               reason: {:blocked, blocked_reason},
               agent_outcome: %Outcome{kind: {:reflex_halted, :progress_stalled}}
             } = await_result(run_id, pid)

      assert blocked_reason =~ "land-cap exhausted after reflex_halt"
      assert_receive {:notify, %Harness.Notification.Event{type: :blocked, task_id: "8", land_attempt: 2}}
    end

    @tag :capture_log
    test "structured redispatch cancel reason settles without crashing and is persisted" do
      store = file_store()
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()
      successor_run_id = "run-redispatched-successor"
      project = ProjectFixture.from_repo(repo, name: "reflex-redispatch-#{System.unique_integer([:positive])}")
      parent = self()

      :ok = ProjectRegistry.register(project)

      Application.put_env(:harness, :roadmap_ingest, fn {:id, "8"}, opts ->
        send(parent, {:ingested_for_redispatch, Keyword.fetch!(opts, :agent)})
        {:ok, item()}
      end)

      Application.put_env(:harness, :run_starter, fn %Item{id: "8"}, ^project, Harness.AgentAdapter.Claude, opts ->
        send(parent, {:started_redispatch, Keyword.fetch!(opts, :land_attempt)})
        {:ok, successor_run_id, self()}
      end)

      on_exit(fn ->
        ProjectRegistry.unregister(project.name)
        Application.delete_env(:harness, :roadmap_ingest)
        Application.delete_env(:harness, :run_starter)
      end)

      opts =
        base
        |> default_opts()
        |> Keyword.merge(
          adapter_opts: [command: :flood],
          progress_timeout: 250,
          result_store: store
        )

      {:ok, run_id, pid} = Run.Supervisor.start_run(item(), project, FakeAdapter, opts)

      assert %Result{
               state: :failed,
               reason: {:redispatched, ^successor_run_id},
               agent_outcome: %Outcome{kind: {:reflex_halted, :progress_stalled}}
             } = await_result(run_id, pid)

      assert_receive {:ingested_for_redispatch, :claude}
      assert_receive {:started_redispatch, 2}

      assert {:ok, [record]} = ResultStore.list_run_records(store, run_id: run_id)
      assert record.state == :failed
      assert record.reason == {:redispatched, successor_run_id}
      refute match?({:run_crashed, _reason}, record.reason)
    end
  end
end
