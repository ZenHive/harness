defmodule Harness.Maintenance.ObanCoverageTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Harness.Oban, as: HarnessOban
  alias Harness.ProjectFixture

  @moduletag :integration

  setup do
    start_supervised!(Harness.Repo)
    :ok = Sandbox.checkout(Harness.Repo)
    old = Application.get_env(:harness, Oban)
    on_exit(fn -> Application.put_env(:harness, Oban, old) end)
    :ok
  end

  test "unfinished task membership excludes settled work and retains coalesced members" do
    project = ProjectFixture.from_repo("/tmp/maintenance-coverage", name: "maintenance-coverage")

    job =
      Harness.Repo.insert!(
        Oban.Job.new(%{"project_name" => project.name, "item_id" => "1", "item_ids" => ["1", "2"]},
          worker: Harness.Run.Worker,
          queue: HarnessOban.queue_name(project)
        )
      )

    assert HarnessOban.unfinished_run_task_groups(project) == %{"1" => ["1", "2"]}
    assert Enum.sort(HarnessOban.unfinished_run_task_ids(project)) == ["1", "2"]
    assert {:ok, %{id: id}} = HarnessOban.coalesced_run_job(project, "2")
    assert id == job.id
    Harness.Repo.update!(Ecto.Changeset.change(job, state: "completed"))
    assert HarnessOban.unfinished_run_task_groups(project) == %{}
  end

  test "queue options normalize absent and disabled plugin configuration" do
    for options <- [[], [queues: false, plugins: false]] do
      Application.put_env(:harness, Oban, options)
      config = HarnessOban.oban_opts()
      assert config[:queues][:insights] == 1
      assert config[:queues][:maintenance] == 1
      assert Keyword.has_key?(config[:plugins], Oban.Cron)
    end

    assert {:ok, {_, children}} = HarnessOban.init([])
    assert match?([_, _, _], children)
  end
end
