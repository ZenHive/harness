defmodule Harness.Run.ReflexFloorTest do
  use Harness.RunCase, async: true

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
               reason: {:reflex_halted, :progress_stalled},
               agent_outcome: %Outcome{kind: {:reflex_halted, :progress_stalled}}
             } = await_result(run_id, pid)

      assert_receive {:notify, %Harness.Notification.Event{type: :blocked, task_id: "8", land_attempt: 2}}
    end
  end
end
