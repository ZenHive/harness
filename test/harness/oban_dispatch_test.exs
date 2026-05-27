defmodule Harness.ObanDispatchTest do
  use ExUnit.Case, async: false

  alias Harness.Batch
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.Roadmap.Item
  alias Harness.Run.Result
  alias Harness.Run.Worker

  setup do
    ProjectRegistry.reset()
    on_exit(fn -> Application.delete_env(:harness, :oban_insert) end)
    on_exit(fn -> Application.delete_env(:harness, :roadmap_ingest) end)
    on_exit(fn -> Application.delete_env(:harness, :run_starter) end)
    on_exit(fn -> Application.delete_env(:harness, :test_worker_result) end)
    :ok
  end

  test "dispatch enqueues one worker job per item into the project's queue" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-dispatch", name: "alpha", concurrency_cap: 2)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      job = Ecto.Changeset.apply_action!(changeset, :insert)
      send(parent, {:inserted, job})
      {:ok, job}
    end)

    assert {:ok, jobs} =
             Batch.dispatch(project, [
               item("48", :claude),
               item("49", :codex)
             ])

    assert length(jobs) == 2

    assert_received {:inserted,
                     %Oban.Job{
                       args: %{
                         project_name: "alpha",
                         item_id: "48",
                         adapter_module: "Elixir.Harness.AgentAdapter.Claude"
                       },
                       meta: %{harness_stage: "dispatch"},
                       queue: "project_alpha",
                       worker: "Harness.Run.Worker"
                     }}

    assert_received {:inserted,
                     %Oban.Job{
                       args: %{
                         project_name: "alpha",
                         item_id: "49",
                         adapter_module: "Elixir.Harness.AgentAdapter.Codex"
                       },
                       queue: "project_alpha"
                     }}
  end

  test "registered project names resolve for dispatch" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-dispatch", name: "registered", concurrency_cap: 1)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      job = Ecto.Changeset.apply_action!(changeset, :insert)
      send(parent, {:inserted, job.queue})
      {:ok, job}
    end)

    assert :ok = ProjectRegistry.register(project)
    assert {:ok, [_job]} = Batch.dispatch("registered", [item("50", :cursor)])
    assert_received {:inserted, "project_registered"}
  end

  test "worker maps terminal run results onto Oban's return contract" do
    assert :ok =
             Worker.to_oban_result(%Result{
               run_id: "run-ok",
               task_id: "1",
               state: :done,
               reason: :passed
             })

    assert {:snooze, seconds} =
             Worker.to_oban_result(%Result{
               run_id: "run-quota",
               task_id: "2",
               state: :failed,
               reason: {:agent_spawn_failed, "429 rate limit"}
             })

    assert is_integer(seconds) and seconds > 0

    assert {:cancel, :verification_red} =
             Worker.to_oban_result(%Result{
               run_id: "run-red",
               task_id: "3",
               state: :failed,
               reason: :verification_red
             })
  end

  test "worker performs a job through project lookup, roadmap ingestion, and run startup" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-worker", name: "worker-project")
    assert :ok = ProjectRegistry.register(project)

    Application.put_env(:harness, :roadmap_ingest, fn selector, opts ->
      send(parent, {:ingest, selector, opts[:project].name, opts[:agent]})
      {:ok, item("48", :claude)}
    end)

    Application.put_env(:harness, :run_starter, fn %Item{} = item, run_project, adapter, opts ->
      send(parent, {:start_run, item.id, run_project.name, adapter, Keyword.fetch!(opts, :batch_id)})
      run_id = "run-worker-ok"
      subscriber = Keyword.fetch!(opts, :subscriber)

      pid =
        spawn(fn ->
          send(
            subscriber,
            {:harness_run, run_id, %Result{run_id: run_id, task_id: item.id, state: :done, reason: :passed}}
          )

          Process.sleep(100)
        end)

      {:ok, run_id, pid}
    end)

    assert :ok =
             Worker.perform(%Oban.Job{
               id: 123,
               attempt: 1,
               args: %{
                 "project_name" => "worker-project",
                 "item_id" => "48",
                 "adapter_module" => "Elixir.Harness.AgentAdapter.Claude"
               }
             })

    assert_received {:ingest, {:id, "48"}, "worker-project", :claude}
    assert_received {:start_run, "48", "worker-project", Harness.AgentAdapter.Claude, "oban-job-123"}
  end

  test "worker maps performed terminal failures to cancel and quota failures to snooze" do
    project = ProjectFixture.from_repo("/tmp/harness-worker", name: "worker-project")
    assert :ok = ProjectRegistry.register(project)

    Application.put_env(:harness, :roadmap_ingest, fn _selector, _opts ->
      {:ok, item("49", :claude)}
    end)

    Application.put_env(:harness, :run_starter, fn item, _project, _adapter, opts ->
      result = Application.fetch_env!(:harness, :test_worker_result)
      run_id = result.run_id
      subscriber = Keyword.fetch!(opts, :subscriber)

      pid =
        spawn(fn ->
          send(subscriber, {:harness_run, run_id, %{result | task_id: item.id}})
          Process.sleep(100)
        end)

      {:ok, run_id, pid}
    end)

    terminal_job =
      job(%{
        "project_name" => "worker-project",
        "item_id" => "49",
        "adapter_module" => "Elixir.Harness.AgentAdapter.Claude"
      })

    terminal_result = %Result{run_id: "run-red", task_id: "49", state: :failed, reason: :verification_red}
    Application.put_env(:harness, :test_worker_result, terminal_result)

    assert {:cancel, :verification_red} =
             Worker.perform(terminal_job)

    quota_result = %Result{
      run_id: "run-quota",
      task_id: "49",
      state: :failed,
      reason: {:agent_spawn_failed, "429 rate limit"}
    }

    Application.put_env(:harness, :test_worker_result, quota_result)

    assert {:snooze, seconds} =
             Worker.perform(%{terminal_job | attempt: 2})

    assert is_integer(seconds) and seconds > 0
  end

  test "worker cancels loudly for invalid job arguments" do
    assert {:cancel, {:missing_arg, "item_id"}} =
             Worker.perform(%Oban.Job{args: %{"project_name" => "missing-item"}})

    project = ProjectFixture.from_repo("/tmp/harness-worker", name: "adapter-check")
    assert :ok = ProjectRegistry.register(project)

    assert {:cancel, {:unsupported_adapter, Harness.AgentAdapter.Grok}} =
             Worker.perform(%Oban.Job{
               args: %{
                 "project_name" => "adapter-check",
                 "item_id" => "1",
                 "adapter_module" => "Elixir.Harness.AgentAdapter.Grok"
               }
             })
  end

  defp item(id, agent) do
    %Item{id: id, title: "Task #{id}", prompt: "do #{id}", agent: agent}
  end

  defp job(args) do
    %Oban.Job{id: 123, attempt: 1, args: args, meta: %{}}
  end
end
