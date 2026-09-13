defmodule Harness.RoadmapSyncTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Harness.GitFixture
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.Roadmap
  alias Harness.Roadmap.Item

  @moduletag :tmp_dir

  setup_all do
    if !System.find_executable("rmap") do
      flunk("""
      rmap CLI not found on PATH.

      Harness.Roadmap shells out to `rmap` — the roadmap substrate. Install it
      (a Rust binary, `cargo install` from the rmap repo) and ensure it is on
      PATH before running this suite.
      """)
    end

    :ok
  end

  @origin_only_id "111"
  @origin_only_body "Filed on origin after the local clone was made."

  @tasks_toml """
  schema_version = 2
  project = "roadmap-sync-fixture"
  default_branch = "main"
  vision = "Roadmap checkout sync fixture."

  [phases.1]
  name = "Fixture Phase"
  order = 1
  status = "in_progress"

  [bundles.fixture]
  description = "Fixture bundle"
  order = 1
  phase = 1

  [[task]]
  id = "2"
  phase = 1
  bundle = "fixture"
  status = "pending"
  title = "Local clone task"
  scores = { d = 2, b = 5, u = 5 }
  acceptance_criteria = ["The clone-local task is ingestible"]
  body = "Present on the clone before origin advances."
  created_at = "2026-06-05"
  """

  @origin_only_task """

  [[task]]
  id = "#{@origin_only_id}"
  phase = 1
  bundle = "fixture"
  status = "pending"
  title = "Origin-only task"
  scores = { d = 2, b = 5, u = 5 }
  acceptance_criteria = ["Ingest reads the body that was pushed after clone"]
  body = "#{@origin_only_body}"
  created_at = "2026-09-11"
  """

  setup do
    %{origin: origin, repo: repo} = GitFixture.init_with_origin()
    seed_roadmap(repo)
    GitFixture.git!(repo, ["push", "-q", "origin", "main"])
    push_origin_only_task(origin)

    project = %Project{
      name: "roadmap-sync-fixture",
      source: {:local, repo},
      roadmap_path: repo,
      languages: [:elixir],
      target_branch: "main"
    }

    %{origin: origin, repo: repo, project: project}
  end

  describe "ingest/2 fetches origin before rmap" do
    test "ingest by id returns a task pushed after the local clone was made", ctx do
      tasks_path = Path.join(ctx.repo, "roadmap/tasks.toml")
      refute File.read!(tasks_path) =~ ~s(id = "#{@origin_only_id}")

      {output, status} =
        System.cmd("rmap", ["show", @origin_only_id, "--json", "--tasks-path", tasks_path], stderr_to_stdout: true)

      assert status == 3, "negative control: rmap on the stale checkout must not find #{@origin_only_id}: #{output}"

      assert {:ok, %Item{} = item} = Roadmap.ingest({:id, @origin_only_id}, project: ctx.project)

      assert item.id == @origin_only_id
      assert item.body == @origin_only_body
      assert File.read!(tasks_path) =~ ~s(id = "#{@origin_only_id}")
    end

    test "ready and next_bundle see the origin-only task after the same sync", ctx do
      ProjectRegistry.reset()
      on_exit(&ProjectRegistry.reset/0)
      assert :ok = ProjectRegistry.register(ctx.project)

      assert {:ok, ready} = Roadmap.ready(project: ctx.project)
      assert Enum.any?(ready, &(&1["id"] == @origin_only_id))

      assert {:ok, %{tasks: tasks}} = Roadmap.next_bundle(ctx.project.name)
      assert Enum.any?(tasks, &(&1["id"] == @origin_only_id))
    end

    test "list/2 opts out: the dashboard display read never fast-forwards the checkout", ctx do
      ProjectRegistry.reset()
      on_exit(&ProjectRegistry.reset/0)
      assert :ok = ProjectRegistry.register(ctx.project)
      local_head = local_tip(ctx.repo)

      assert {:ok, tasks} = Roadmap.list(ctx.project.name)

      refute Enum.any?(tasks, &(&1["id"] == @origin_only_id))
      assert local_tip(ctx.repo) == local_head
      refute File.read!(Path.join(ctx.repo, "roadmap/tasks.toml")) =~ ~s(id = "#{@origin_only_id}")
    end
  end

  describe "ingest/2 skip is witnessed and never forced" do
    test "dirty checkout is skipped; ingest still runs on the local file", ctx do
      File.write!(Path.join(ctx.repo, "scratch.txt"), "operator mid-edit\n")
      local_head = local_tip(ctx.repo)

      log =
        capture_log(fn ->
          assert {:error, {:task_not_found, @origin_only_id}} =
                   Roadmap.ingest({:id, @origin_only_id}, project: ctx.project)

          assert {:ok, %Item{id: "2"}} = Roadmap.ingest({:id, "2"}, project: ctx.project)
        end)

      assert log =~ "harness roadmap: checkout not fast-forwarded"
      assert log =~ "sync manually"
      assert local_tip(ctx.repo) == local_head
      assert File.read!(Path.join(ctx.repo, "scratch.txt")) == "operator mid-edit\n"
      refute File.read!(Path.join(ctx.repo, "roadmap/tasks.toml")) =~ ~s(id = "#{@origin_only_id}")
    end

    test "non-ff divergence is skipped and never forced", ctx do
      File.write!(Path.join(ctx.repo, "local.txt"), "operator\n")
      GitFixture.git!(ctx.repo, ["add", "local.txt"])
      GitFixture.git!(ctx.repo, ["commit", "-q", "-m", "operator work"])
      local_head = local_tip(ctx.repo)

      log =
        capture_log(fn ->
          assert {:error, {:task_not_found, @origin_only_id}} =
                   Roadmap.ingest({:id, @origin_only_id}, project: ctx.project)
        end)

      assert log =~ "harness roadmap: checkout not fast-forwarded"
      assert log =~ "sync manually"
      refute log =~ "self-host"
      assert local_tip(ctx.repo) == local_head
      assert File.read!(Path.join(ctx.repo, "local.txt")) == "operator\n"
    end

    test "a detached HEAD is skipped and ingest proceeds on the on-disk file", ctx do
      GitFixture.git!(ctx.repo, ["checkout", "--detach", "-q"])
      detached_head = local_tip(ctx.repo)

      log =
        capture_log(fn ->
          assert {:error, {:task_not_found, @origin_only_id}} =
                   Roadmap.ingest({:id, @origin_only_id}, project: ctx.project)

          assert {:ok, %Item{id: "2"}} = Roadmap.ingest({:id, "2"}, project: ctx.project)
        end)

      assert log =~ "detached HEAD"
      assert local_tip(ctx.repo) == detached_head
    end

    test "self-host skip follows TargetSync path identity, not the project name", ctx do
      previous = Application.get_env(:harness, :node_source_root)
      Application.put_env(:harness, :node_source_root, ctx.repo)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:harness, :node_source_root)
        else
          Application.put_env(:harness, :node_source_root, previous)
        end
      end)

      local_head = local_tip(ctx.repo)

      log =
        capture_log(fn ->
          assert {:error, {:task_not_found, @origin_only_id}} =
                   Roadmap.ingest({:id, @origin_only_id}, project: ctx.project)
        end)

      assert log =~ "self-host"
      assert local_tip(ctx.repo) == local_head
      refute File.read!(Path.join(ctx.repo, "roadmap/tasks.toml")) =~ ~s(id = "#{@origin_only_id}")
    end

    test "a non-git roadmap_path is skipped; ingest still runs on the local file", ctx do
      roadmap_root = GitFixture.tmp_base(name: "roadmap-sync-non-git")
      File.mkdir_p!(roadmap_root)
      File.cp_r!(Path.join(ctx.repo, "roadmap"), Path.join(roadmap_root, "roadmap"))
      File.cp!(Path.join(ctx.repo, "ROADMAP.md"), Path.join(roadmap_root, "ROADMAP.md"))

      project =
        ctx.project
        |> Map.put(:roadmap_path, roadmap_root)
        |> Map.replace!(:roadmap_target_branch, "main")

      log =
        capture_log(fn ->
          assert {:ok, %Item{id: "2"}} = Roadmap.ingest({:id, "2"}, project: project)

          assert {:error, {:task_not_found, @origin_only_id}} =
                   Roadmap.ingest({:id, @origin_only_id}, project: project)
        end)

      assert log =~ "not a git work tree"
      assert File.read!(Path.join(roadmap_root, "roadmap/tasks.toml")) =~ ~s(id = "2")
    end
  end

  describe "writeback syncs before committing" do
    test "mark_in_progress lands on top of the freshly fetched origin tip", ctx do
      origin_before = origin_tip(ctx.repo)
      refute origin_before == local_tip(ctx.repo)

      assert {:ok, _output} = Roadmap.mark_in_progress("2", project: ctx.project)

      assert origin_task_status(ctx.repo, "2") == "in_progress"
      assert origin_log(ctx.repo) =~ "roadmap: task 2 -> in_progress"
      GitFixture.git!(ctx.repo, ["merge-base", "--is-ancestor", origin_before, "origin/main"])
    end
  end

  @spec seed_roadmap(String.t()) :: :ok
  defp seed_roadmap(repo) do
    File.mkdir_p!(Path.join(repo, "roadmap"))
    File.write!(Path.join(repo, "roadmap/tasks.toml"), @tasks_toml)
    File.write!(Path.join(repo, "ROADMAP.md"), "# Roadmap\n\n<!-- TASKS:BEGIN phase=1 -->\n<!-- TASKS:END -->\n")

    {_out, 0} =
      System.cmd("rmap", ["render", "--tasks-path", Path.join(repo, "roadmap/tasks.toml")], stderr_to_stdout: true)

    GitFixture.git!(repo, ["add", "-A"])
    GitFixture.git!(repo, ["commit", "-q", "-m", "seed roadmap"])
    :ok
  end

  @spec push_origin_only_task(String.t()) :: :ok
  defp push_origin_only_task(origin) do
    clone = Path.join(System.tmp_dir!(), "roadmap-sync-ahead-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(clone) end)

    {_out, 0} = System.cmd("git", ["clone", "-q", origin, clone], stderr_to_stdout: true)
    GitFixture.git!(clone, ["config", "user.email", "ahead@example.com"])
    GitFixture.git!(clone, ["config", "user.name", "Ahead"])

    File.write!(Path.join(clone, "roadmap/tasks.toml"), @tasks_toml <> @origin_only_task)

    {_out, 0} =
      System.cmd("rmap", ["render", "--tasks-path", Path.join(clone, "roadmap/tasks.toml")], stderr_to_stdout: true)

    GitFixture.git!(clone, ["add", "-A"])
    GitFixture.git!(clone, ["commit", "-q", "-m", "add origin-only task #{@origin_only_id}"])
    GitFixture.git!(clone, ["push", "-q", "origin", "main"])
    :ok
  end

  @spec origin_task_status(String.t(), String.t()) :: String.t()
  defp origin_task_status(repo, id) do
    toml = origin_show(repo, "roadmap/tasks.toml")
    path = Path.join(System.tmp_dir!(), "roadmap-sync-verify-#{System.unique_integer([:positive])}.toml")
    File.write!(path, toml)
    on_exit(fn -> File.rm(path) end)

    {out, 0} = System.cmd("rmap", ["show", id, "--json", "--tasks-path", path], stderr_to_stdout: true)
    out |> JSON.decode!() |> Map.fetch!("status")
  end

  @spec origin_show(String.t(), String.t()) :: String.t()
  defp origin_show(repo, file) do
    GitFixture.git!(repo, ["fetch", "-q", "origin", "main"])
    GitFixture.git!(repo, ["show", "origin/main:#{file}"])
  end

  @spec origin_log(String.t()) :: String.t()
  defp origin_log(repo) do
    GitFixture.git!(repo, ["fetch", "-q", "origin", "main"])
    GitFixture.git!(repo, ["log", "--format=%s", "origin/main"])
  end

  @spec origin_tip(String.t()) :: String.t()
  defp origin_tip(repo) do
    GitFixture.git!(repo, ["fetch", "-q", "origin", "main"])
    repo |> GitFixture.git!(["rev-parse", "origin/main"]) |> String.trim()
  end

  @spec local_tip(String.t()) :: String.t()
  defp local_tip(repo) do
    repo |> GitFixture.git!(["rev-parse", "HEAD"]) |> String.trim()
  end
end
