defmodule Harness.Cron.InFlightTest do
  # async: false because tests mutate :live_run_statuses / :roadmap_list app env.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Harness.Cron.InFlight
  alias Harness.ProjectFixture
  alias Harness.Run.Status
  alias Harness.Run.Worker

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

  @tag :integration
  test "unfinished jobs count without live runs, independently of roadmap status or read errors" do
    start_supervised!(Harness.Repo)
    :ok = Sandbox.checkout(Harness.Repo)
    project = ProjectFixture.from_repo("/tmp/harness-inflight-queued", name: "inflight-queued")
    Application.put_env(:harness, :live_run_statuses, fn -> [] end)

    for {id, state} <- [
          {"1", "available"},
          {"2", "scheduled"},
          {"3", "retryable"},
          {"4", "executing"},
          {"5", "completed"},
          {"6", "cancelled"},
          {"7", "discarded"}
        ] do
      args = %{project_name: project.name, item_id: id, adapter_module: "Elixir.Harness.AgentAdapter.Codex"}
      changeset = Worker.new(args, queue: Harness.Oban.queue_name(project))
      assert {:ok, _job} = Harness.Repo.insert(Ecto.Changeset.put_change(changeset, :state, state))
    end

    for id <- ~w(1 2 3 4), do: assert(InFlight.run_in_flight?(project, id))
    for id <- ~w(5 6 7), do: refute(InFlight.run_in_flight?(project, id))

    # A live run and its persisted job occupy one dispatch identity.
    Application.put_env(:harness, :live_run_statuses, fn ->
      [%Status{run_id: "run-queued", project_name: project.name, task_id: "1", state: :running}]
    end)

    assert Harness.Oban.coalesced_run_job(project, "1") == :error

    row = %{"id" => "1", "status" => "pending", "touches" => ["lib/queued.ex"]}
    Application.put_env(:harness, :roadmap_list, fn _ -> {:ok, [row]} end)
    snapshot = InFlight.snapshot(project)
    assert snapshot.occupancy == 4
    assert snapshot.rmap_in_progress == 0
    assert row in snapshot.tasks
    assert Enum.sort(Enum.map(snapshot.tasks, & &1["id"])) == ~w(1 2 3 4)

    Application.put_env(:harness, :roadmap_list, fn _ -> {:error, :unavailable} end)
    assert %{occupancy: 4, rmap_in_progress: :unread} = InFlight.snapshot(project)
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
