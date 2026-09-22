defmodule Harness.Maintenance.QueueTest do
  use ExUnit.Case, async: false

  alias Harness.Insights.Attempt
  alias Harness.Maintenance
  alias Harness.Maintenance.Publication
  alias Harness.Maintenance.Store
  alias Harness.Maintenance.Worker
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry

  @moduletag :integration

  setup do
    old = Application.get_env(:harness, :repo_enabled)
    Application.put_env(:harness, :repo_enabled, true)
    start_supervised!(Harness.Repo)
    start_supervised!({Oban, name: Harness.Oban, repo: Harness.Repo, testing: :manual, queues: false, plugins: false})
    name = "maintenance-queue-#{Ecto.UUID.generate()}"
    :ok = ProjectRegistry.register(ProjectFixture.from_repo("/tmp/maintenance-queue", name: name))

    on_exit(fn ->
      # Unregister BEFORE restoring repo_enabled: ProjectRegistry.Persistence.delete/1
      # is a no-op once the repo is disabled, so the reverse order leaves the row in
      # the live `projects` table. Fourteen `maintenance-queue-<uuid>` projects leaked
      # that way (2026-09-20/21) and the Maintenance tick then swept them hourly into
      # `source_unavailable` failures.
      ProjectRegistry.unregister(name)
      Application.put_env(:harness, :repo_enabled, old)
    end)

    :ok = Maintenance.configure(name, true, 10_080, "codex", "gpt-6-astra", 60)
    %{name: name}
  end

  test "concurrent triggers produce one job and pin the configured deadline", %{name: name} do
    jobs = 1..8 |> Task.async_stream(fn _ -> Maintenance.sweep_now(name) end) |> Enum.map(fn {:ok, {:ok, id}} -> id end)
    assert [_] = Enum.uniq(jobs)
    assert Maintenance.status(name)["state"] == "queued"
    assert Worker.timeout(%Oban.Job{args: %{"project" => name}}) == 60_000
    assert Harness.Oban.oban_opts()[:queues][:maintenance] == 1
  end

  test "a worker on another connection snoozes while a sweep owns the fleet lock", %{name: name} do
    parent = self()

    owner =
      Task.async(fn ->
        Store.serialized(fn ->
          send(parent, :locked)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :locked
    assert {:snooze, 60} = Worker.perform(%Oban.Job{args: %{"project" => name, "pass_id" => Ecto.UUID.generate()}})
    send(owner.pid, :release)
    assert :ok = Task.await(owner)
  end

  test "running coalesced tasks count even if their roadmap status was marked done", %{name: name} do
    tasks =
      Enum.map(1..3, fn id ->
        %{
          "id" => to_string(id),
          "status" => "done",
          "body" => "Fixture\n" <> Publication.identity(name, to_string(id)) <> "\n"
        }
      end)

    assert {:ok, 0} = Publication.unfinished_count(tasks, name)

    job =
      Harness.Repo.insert!(
        Oban.Job.new(%{"project_name" => name, "item_id" => "1", "item_ids" => ["1", "2", "3"]},
          worker: Harness.Run.Worker,
          queue: Harness.Oban.queue_name(name)
        )
      )

    assert {:ok, 3} = Publication.unfinished_count(tasks, name)
    Harness.Repo.update!(Ecto.Changeset.change(job, state: "completed"))
    assert {:ok, 0} = Publication.unfinished_count(tasks, name)
  end

  test "interrupted publication is visibly failed and a new job retains its pass id", %{name: name} do
    id = Ecto.UUID.generate()
    task = Task.async(fn -> Attempt.owner() end)
    owner = Task.await(task)

    pass = %{
      "id" => id,
      "project" => name,
      "state" => "running",
      "committed" => false,
      "owner" => owner,
      "expires_at" => "2099-01-01T00:00:00Z",
      "at" => DateTime.to_iso8601(DateTime.utc_now()),
      "findings" => [%{"id" => "pending-publication", "publication_id" => "maintenance-stable"}]
    }

    :ok = Store.put_many([{"pass/" <> id, "pass", pass}, {"progress/" <> name, "progress", Map.delete(pass, "findings")}])
    assert Maintenance.status(name)["state"] == "failed"
    assert Maintenance.status(name)["progress"]["error"] == "interrupted"
    assert {:ok, job_id} = Maintenance.sweep_now(name)
    assert Harness.Repo.get!(Oban.Job, job_id).args["pass_id"] == id
  end

  test "a committed pass repairs progress after its worker dies before the progress checkpoint", %{name: name} do
    id = Ecto.UUID.generate()
    owner = fn -> Attempt.owner() end |> Task.async() |> Task.await()

    progress = %{
      "id" => id,
      "project" => name,
      "state" => "running",
      "owner" => owner,
      "expires_at" => "2099-01-01T00:00:00Z"
    }

    pass = Map.merge(progress, %{"state" => "successful", "committed" => true, "findings" => []})
    :ok = Store.put_many([{"pass/" <> id, "pass", pass}, {"progress/" <> name, "progress", progress}])

    assert Maintenance.status(name)["state"] == "successful"
    assert Store.get("pass/" <> id)["committed"]
    refute Store.get("progress/" <> name)["error"]
  end

  test "abandoned running progress without a pass document is marked interrupted", %{name: name} do
    owner = fn -> Attempt.owner() end |> Task.async() |> Task.await()

    progress = %{
      "id" => Ecto.UUID.generate(),
      "project" => name,
      "state" => "running",
      "owner" => owner,
      "expires_at" => "2099-01-01T00:00:00Z"
    }

    :ok = Store.put_many([{"progress/" <> name, "progress", progress}])
    assert Maintenance.status(name)["state"] == "failed"
    assert Maintenance.status(name)["progress"]["error"] == "interrupted"
  end
end
