defmodule Harness.Cron.InFlightTest do
  # async: false because tests mutate :live_run_statuses / :roadmap_list app env.
  use ExUnit.Case, async: false

  alias Harness.Cron.InFlight
  alias Harness.ProjectFixture
  alias Harness.Run.Status

  setup do
    on_exit(fn ->
      Application.delete_env(:harness, :live_run_statuses)
      Application.delete_env(:harness, :roadmap_list)
    end)

    :ok
  end

  describe "run_in_flight?/2" do
    test "is true for a live run in an in-flight state" do
      project = ProjectFixture.from_repo("/tmp/harness-inflight-live", name: "inflight-live")

      Application.put_env(:harness, :live_run_statuses, fn ->
        [%Status{run_id: "run-12", project_name: project.name, task_id: "12", state: :running}]
      end)

      assert InFlight.run_in_flight?(project, "12")
      refute InFlight.run_in_flight?(project, "4")
    end

    test "is false for a settled run of the same task id" do
      project = ProjectFixture.from_repo("/tmp/harness-inflight-settled", name: "inflight-settled")

      Application.put_env(:harness, :live_run_statuses, fn ->
        [%Status{run_id: "run-4", project_name: project.name, task_id: "4", state: :done}]
      end)

      refute InFlight.run_in_flight?(project, "4")
    end
  end

  describe "tasks/1 and snapshot/1" do
    test "rmap in_progress with zero live runs and zero Oban jobs is not occupancy" do
      project = ProjectFixture.from_repo("/tmp/harness-inflight-phantom", name: "inflight-phantom", concurrency_cap: 4)
      Application.put_env(:harness, :live_run_statuses, fn -> [] end)

      Application.put_env(:harness, :roadmap_list, fn _project ->
        {:ok,
         for id <- ["4", "12", "22", "23"] do
           %{"id" => id, "status" => "in_progress", "touches" => ["lib/#{id}.ex"]}
         end}
      end)

      assert InFlight.tasks(project) == []

      snapshot = InFlight.snapshot(project)
      assert snapshot.cap == 4
      assert snapshot.occupancy == 0
      assert snapshot.rmap_in_progress == 4
      assert snapshot.tasks == []
    end

    test "a live in-flight run is reported with its rmap touches; a settled sibling is not" do
      project = ProjectFixture.from_repo("/tmp/harness-inflight-mix", name: "inflight-mix", concurrency_cap: 4)

      Application.put_env(:harness, :live_run_statuses, fn ->
        [
          %Status{run_id: "run-12", project_name: project.name, task_id: "12", state: :running},
          %Status{run_id: "run-4", project_name: project.name, task_id: "4", state: :done}
        ]
      end)

      Application.put_env(:harness, :roadmap_list, fn _project ->
        {:ok,
         [
           %{"id" => "4", "status" => "in_progress", "touches" => ["lib/settled.ex"]},
           %{
             "id" => "12",
             "status" => "in_progress",
             "touches" => ["lib/starpatron/media.ex"],
             "files_to_modify" => ["lib/starpatron/media.ex"]
           }
         ]}
      end)

      assert [%{"id" => "12", "touches" => ["lib/starpatron/media.ex"]} = live] = InFlight.tasks(project)
      assert live["files_to_modify"] == ["lib/starpatron/media.ex"]
      assert InFlight.snapshot(project).occupancy == 1
      assert InFlight.snapshot(project).rmap_in_progress == 2
    end

    test "a live id missing from rmap still occupies a slot as an id-only row" do
      project = ProjectFixture.from_repo("/tmp/harness-inflight-orphan", name: "inflight-orphan")

      Application.put_env(:harness, :live_run_statuses, fn ->
        [%Status{run_id: "run-99", project_name: project.name, task_id: "99", state: :reviewing}]
      end)

      Application.put_env(:harness, :roadmap_list, fn _project -> {:ok, []} end)

      assert InFlight.tasks(project) == [%{"id" => "99"}]
    end

    test "an unreadable roadmap reports rmap_in_progress as :unread, not zero" do
      project = ProjectFixture.from_repo("/tmp/harness-inflight-unread", name: "inflight-unread", concurrency_cap: 2)
      Application.put_env(:harness, :live_run_statuses, fn -> [] end)
      Application.put_env(:harness, :roadmap_list, fn _project -> {:error, :roadmap_not_found} end)

      snapshot = InFlight.snapshot(project)
      assert snapshot.occupancy == 0
      assert snapshot.rmap_in_progress == :unread
    end
  end
end
