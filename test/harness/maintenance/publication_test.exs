defmodule Harness.Maintenance.PublicationTest do
  use ExUnit.Case, async: false

  alias Harness.GitFixture
  alias Harness.Maintenance
  alias Harness.Maintenance.Publication
  alias Harness.Maintenance.Store
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry

  setup do
    %{repo: repo} = GitFixture.init_with_origin(name: "maintenance-publication")
    File.mkdir_p!(Path.join(repo, "roadmap"))
    File.write!(Path.join(repo, "ROADMAP.md"), "# Fixture Roadmap\n")

    File.write!(
      Path.join(repo, "roadmap/tasks.toml"),
      ~s(schema_version = 2\nproject = "maintenance-publication"\ndefault_branch = "main"\nvision = "Publication fixture"\n[phases.1]\nname = "Maintenance"\norder = 1\nstatus = "pending"\n[bundles.maintenance]\nphase = 1\norder = 1\ndescription = "Fixture maintenance"\n\n[[task]]\nid = "1"\nphase = 1\nbundle = "maintenance"\nstatus = "done"\nimplemented = "Created disposable test fixture"\ndone_at = "2026-09-20"\ntitle = "Create disposable fixture"\nscores = { d = 1, b = 1, u = 1 }\n)
    )

    GitFixture.git!(repo, ["add", "ROADMAP.md", "roadmap/tasks.toml"])
    GitFixture.git!(repo, ["commit", "-qm", "roadmap"])
    GitFixture.git!(repo, ["push", "-q", "origin", "main"])
    project = ProjectFixture.from_repo(repo, name: "maintenance-publication", target_branch: "main")
    :ok = ProjectRegistry.register(project)
    old = Application.get_env(:harness, :agent_model)
    Application.put_env(:harness, :agent_model, codex: "gpt-6-astra")
    Application.put_env(:harness, :maintenance_agent, Harness.Test.MaintenanceAnalyst)
    Application.delete_env(:harness, :maintenance_test_mode)
    Store.get("init")
    :ets.delete_all_objects(Store)
    :ok = Maintenance.configure(project.name, true, 10_080, "codex", "gpt-6-astra", 60)

    on_exit(fn ->
      ProjectRegistry.unregister(project.name)
      Application.put_env(:harness, :agent_model, old)
      Application.delete_env(:harness, :maintenance_agent)
      Application.delete_env(:harness, :maintenance_test_mode)
      Application.delete_env(:harness, :maintenance_test_hook)
      :ets.delete_all_objects(Store)
    end)

    %{project: project, repo: repo}
  end

  test "three unfinished tasks, retained findings and replay after pushed-but-uncheckpointed publication", %{
    project: project,
    repo: repo
  } do
    id = Ecto.UUID.generate()
    assert :ok = Maintenance.sweep(project.name, id)
    assert {:ok, all_tasks, _} = Publication.read(repo)
    tasks = Enum.filter(all_tasks, &Publication.maintenance_task?(&1, project.name))
    assert Enum.count_until(tasks, 4) == 3
    assert Enum.all?(tasks, &(&1["status"] == "pending" and Publication.maintenance_task?(&1, project.name)))
    assert Enum.count_until(Maintenance.findings(project.name)["items"], 6) == 5
    assert Maintenance.status(project.name)["tasks"]["outstanding"] == 3
    pass = Store.get("pass/" <> id)
    # Recreate the durable intent checkpoint that exists immediately before the remote push.
    intent =
      Map.merge(pass, %{"committed" => false, "findings" => Enum.map(pass["findings"], &Map.put(&1, "task_id", nil))})

    :ok = Store.put_many([{"pass/" <> id, "pass", intent}])
    before = GitFixture.git!(repo, ["ls-remote", "origin", "refs/heads/main"])
    assert :ok = Maintenance.sweep(project.name, id)
    assert GitFixture.git!(repo, ["ls-remote", "origin", "refs/heads/main"]) == before
    assert Enum.count(Maintenance.findings(project.name)["items"], &is_binary(&1["task_id"])) == 3
    assert :ok = Maintenance.sweep(project.name, Ecto.UUID.generate())
    assert {:ok, all_tasks, _} = Publication.read(repo)
    tasks = Enum.filter(all_tasks, &Publication.maintenance_task?(&1, project.name))
    assert Enum.count_until(tasks, 4) == 3
    assert GitFixture.git!(repo, ["status", "--porcelain"]) == ""
  end

  test "an empty roadmap receives its first provider-validated numeric task", %{project: project, repo: repo} do
    path = Path.join(repo, "roadmap/tasks.toml")
    File.write!(path, path |> File.read!() |> String.split("[[task]]") |> hd())
    GitFixture.git!(repo, ["add", "roadmap/tasks.toml"])
    GitFixture.git!(repo, ["commit", "-qm", "empty roadmap fixture"])
    GitFixture.git!(repo, ["push", "-q", "origin", "main"])
    assert :ok = Maintenance.sweep(project.name, Ecto.UUID.generate())
    assert {:ok, tasks, _} = Publication.read(repo)
    assert Enum.sort(Enum.map(tasks, & &1["id"])) == ["1", "2", "3"]
  end

  test "a concurrent roadmap commit is preserved when durable publication replays", %{project: project, repo: repo} do
    Application.put_env(:harness, :maintenance_test_hook, fn context ->
      if context["mode"] == "publication" do
        Application.delete_env(:harness, :maintenance_test_hook)
        File.write!(Path.join(repo, "roadmap/tasks.toml"), "\n# Concurrent writer evidence\n", [:append])
        GitFixture.git!(repo, ["add", "roadmap/tasks.toml"])
        GitFixture.git!(repo, ["commit", "-qm", "concurrent roadmap change"])
        GitFixture.git!(repo, ["push", "-q", "origin", "main"])
      end
    end)

    assert :ok = Maintenance.sweep(project.name, Ecto.UUID.generate())
    assert {:ok, tasks, raw} = Publication.read(repo)
    assert raw =~ "Concurrent writer evidence"
    assert Enum.count(tasks, &Publication.maintenance_task?(&1, project.name)) == 3
  end

  test "removed publication markers cannot be recreated after a crash", %{project: project, repo: repo} do
    id = Ecto.UUID.generate()
    assert :ok = Maintenance.sweep(project.name, id)
    pass = Store.get("pass/" <> id)
    published = Enum.find(pass["findings"], &is_binary(&1["task_id"]))
    roadmap = Path.join(repo, "roadmap/tasks.toml")
    File.write!(roadmap, String.replace(File.read!(roadmap), published["publication_id"], "removed identity"))
    GitFixture.git!(repo, ["add", "roadmap/tasks.toml"])
    GitFixture.git!(repo, ["commit", "-qm", "remove publication marker"])
    GitFixture.git!(repo, ["push", "-q", "origin", "main"])
    :ok = Store.put_many([{"pass/" <> id, "pass", Map.put(pass, "committed", false)}])
    assert {:error, :publication_history_unknown} = Maintenance.sweep(project.name, id)
  end

  test "unknown publication history stops writing, and failures remain visible", %{project: project, repo: repo} do
    :ok =
      Store.put_many([
        {"finding/missing", "finding/" <> project.name, %{"id" => "missing", "task_id" => "maintenance-missing"}}
      ])

    before = GitFixture.git!(repo, ["ls-remote", "origin", "refs/heads/main"])
    Application.put_env(:harness, :maintenance_test_mode, :empty)
    assert {:error, :publication_history_unknown} = Maintenance.sweep(project.name, Ecto.UUID.generate())
    assert Maintenance.status(project.name)["state"] == "failed"
    assert GitFixture.git!(repo, ["ls-remote", "origin", "refs/heads/main"]) == before
  end

  test "successful empty pass differs from unsafe publication and provider failure", %{project: project} do
    Application.put_env(:harness, :maintenance_test_mode, :empty)
    assert :ok = Maintenance.sweep(project.name, Ecto.UUID.generate())
    assert Maintenance.status(project.name)["state"] == "partial_evidence"
    Application.put_env(:harness, :maintenance_test_mode, :unsafe)
    assert {:error, :publication_not_safe} = Maintenance.sweep(project.name, Ecto.UUID.generate())
    Application.put_env(:harness, :maintenance_test_mode, :fail)
    assert {:error, :agent_failed} = Maintenance.sweep(project.name, Ecto.UUID.generate())
  end

  test "unavailable consumer verification retains blocked findings without executable tasks", %{
    project: project,
    repo: repo
  } do
    Application.put_env(:harness, :maintenance_test_mode, :blocked)
    assert :ok = Maintenance.sweep(project.name, Ecto.UUID.generate())
    assert Enum.all?(Maintenance.findings(project.name)["items"], &(&1["blocked"] && is_nil(&1["task_id"])))
    assert {:ok, tasks, _} = Publication.read(repo)
    refute Enum.any?(tasks, &Publication.maintenance_task?(&1, project.name))
  end

  test "missing roadmap refuses publication and malformed finding transport is rejected", %{repo: repo} do
    assert {:error, :roadmap_unavailable} = Publication.read(Path.join(repo, "missing"))
    assert {:error, :invalid_findings} = Publication.validate(%{})

    assert {:error, :invalid_findings} =
             Publication.validate(%{
               "findings" => [nil],
               "partial_evidence" => false,
               "publication_safe" => true,
               "rationale" => ""
             })
  end

  test "retained findings beyond one dashboard page do not freeze publication", %{project: project} do
    documents =
      Enum.map(1..51, fn n ->
        id = "retained-#{n}"
        {"finding/" <> id, "finding/" <> project.name, %{"id" => id, "project" => project.name}}
      end)

    assert :ok = Store.put_many(documents)
    Application.put_env(:harness, :maintenance_test_mode, :empty)
    assert :ok = Maintenance.sweep(project.name, Ecto.UUID.generate())
    assert Maintenance.status(project.name)["state"] == "partial_evidence"
  end
end
