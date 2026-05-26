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

  defp item(id, agent) do
    %Item{id: id, title: "Task #{id}", prompt: "do #{id}", agent: agent}
  end
end
