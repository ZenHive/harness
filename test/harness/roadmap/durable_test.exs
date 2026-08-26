defmodule Harness.Roadmap.DurableTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Harness.GitFixture
  alias Harness.Project
  alias Harness.Roadmap
  alias Harness.Roadmap.Durable

  @moduletag :tmp_dir

  setup_all do
    if !System.find_executable("rmap") do
      flunk("""
      rmap CLI not found on PATH.

      Harness.Roadmap.Durable shells out to `rmap` — the roadmap substrate.
      Install it (a Rust binary, `cargo install` from the rmap repo) and ensure
      it is on PATH before running this suite.
      """)
    end

    :ok
  end

  # Two pending tasks on the seeded roadmap, so a transition on one and a
  # transition on the other prove neither clobbers the other's edit.
  @tasks_toml """
  schema_version = 2
  project = "durable-fixture"
  default_branch = "main"
  vision = "Durable roadmap write fixture."

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
  title = "First durable task"
  scores = { d = 2, b = 5, u = 5 }
  body = "First."
  created_at = "2026-06-05"

  [[task]]
  id = "3"
  phase = 1
  bundle = "fixture"
  status = "pending"
  title = "Second durable task"
  scores = { d = 2, b = 5, u = 5 }
  body = "Second."
  created_at = "2026-06-05"
  """

  setup do
    %{origin: origin, repo: repo} = GitFixture.init_with_origin()

    File.mkdir_p!(Path.join(repo, "roadmap"))
    File.write!(Path.join(repo, "roadmap/tasks.toml"), @tasks_toml)
    # rmap status re-renders ROADMAP.md + data.json on every transition and
    # reads the existing ROADMAP.md to byte-preserve prose around its marker
    # pairs, so seed a minimal one + render — mirroring a real project's layout.
    File.write!(Path.join(repo, "ROADMAP.md"), "# Roadmap\n\n<!-- TASKS:BEGIN phase=1 -->\n<!-- TASKS:END -->\n")

    {_out, 0} =
      System.cmd("rmap", ["render", "--tasks-path", Path.join(repo, "roadmap/tasks.toml")], stderr_to_stdout: true)

    GitFixture.git!(repo, ["add", "-A"])
    GitFixture.git!(repo, ["commit", "-q", "-m", "seed roadmap"])
    GitFixture.git!(repo, ["push", "-q", "origin", "main"])

    project = %Project{
      name: "durable-fixture",
      source: {:local, repo},
      roadmap_path: repo,
      languages: [:elixir],
      target_branch: "main"
    }

    %{origin: origin, repo: repo, project: project}
  end

  describe "durable transition through Roadmap.mark_*/2" do
    test "pushes the transition to the target branch as a durable commit", ctx do
      assert {:ok, _output} = Roadmap.mark_in_progress("2", project: ctx.project)

      assert origin_task_status(ctx.repo, "2") == "in_progress"
      assert origin_log(ctx.repo) =~ "roadmap: task 2 -> in_progress"
    end

    test "fast-forwards the operator's local checkout so tasks.toml stays in sync", ctx do
      # The operator clone is on the target branch with a clean tree, so the
      # post-push sync must advance its working copy — otherwise local tasks.toml
      # drifts behind origin and the operator's next merge breaks.
      assert String.trim(GitFixture.git!(ctx.repo, ["branch", "--show-current"])) == "main"

      assert {:ok, _output} = Roadmap.mark_in_progress("2", project: ctx.project)

      assert local_task_status(ctx.repo, "2") == "in_progress"
    end

    test "skips the local sync when the roadmap repo is this node's own source tree", ctx do
      previous = Application.get_env(:harness, :node_source_root)
      Application.put_env(:harness, :node_source_root, ctx.repo)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:harness, :node_source_root)
        else
          Application.put_env(:harness, :node_source_root, previous)
        end
      end)

      head_before = local_tip(ctx.repo)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _output} = Roadmap.mark_in_progress("2", project: ctx.project)
        end)

      assert origin_task_status(ctx.repo, "2") == "in_progress"
      assert local_task_status(ctx.repo, "2") == "pending"
      assert local_tip(ctx.repo) == head_before
      assert log =~ "self-host"
    end

    test "skips the local sync without clobbering a dirty operator checkout", ctx do
      File.write!(Path.join(ctx.repo, "scratch.txt"), "operator mid-edit\n")

      assert {:ok, _output} = Roadmap.mark_in_progress("2", project: ctx.project)

      # Pushed to origin, but the dirty local tree is left alone (not ff'd, not
      # clobbered) — the operator syncs manually once their tree is clean.
      assert origin_task_status(ctx.repo, "2") == "in_progress"
      assert local_task_status(ctx.repo, "2") == "pending"
      assert File.read!(Path.join(ctx.repo, "scratch.txt")) == "operator mid-edit\n"
    end

    test "dispatch-start and post-land commits reach origin while the operator is dirty and ahead", ctx do
      File.write!(Path.join(ctx.repo, "operator.txt"), "local commit\n")
      GitFixture.git!(ctx.repo, ["add", "operator.txt"])
      GitFixture.git!(ctx.repo, ["commit", "-q", "-m", "operator unpushed work"])
      File.write!(Path.join(ctx.repo, "scratch.txt"), "dirty operator edit\n")
      local_head = local_tip(ctx.repo)

      assert {:ok, _output} = Roadmap.mark_in_progress("2", project: ctx.project)
      in_progress_tip = origin_tip(ctx.repo)
      assert origin_log(ctx.repo) =~ "roadmap: task 2 -> in_progress"

      shipped = "0123456789abcdef0123456789abcdef01234567"

      assert {:ok, _output} =
               Roadmap.mark_landed("2",
                 project: ctx.project,
                 sha: shipped,
                 verified_by: "codex",
                 verification_ref: "harness-run:run-durable",
                 implemented:
                   "run-1785889534260-fc424f54: Durable trusted git-push exit 0 without observing origin, so a push that did not land looked identical to success; callers logged without run_id. run-1786522856472-c6cebe49: lander ran sync/audit/prune before mark_landed, so a job death after delivery push lost the done writeback and success log."
               )

      assert origin_tip(ctx.repo) != in_progress_tip
      assert origin_log(ctx.repo) =~ "roadmap: task 2 -> done"
      task = origin_task(ctx.repo, "2")
      assert task["status"] == "done"
      assert task["verified"] == true
      assert task["verified_by"] == "codex"
      assert task["verification_ref"] == "harness-run:run-durable"
      assert task["shipped_in"] == shipped
      assert is_binary(task["started_at"])

      assert local_tip(ctx.repo) == local_head
      assert File.read!(Path.join(ctx.repo, "scratch.txt")) == "dirty operator edit\n"
      refute origin_log(ctx.repo) =~ "operator unpushed work"
    end

    test "a push origin does not retain is an error, not a silent ok", ctx do
      hook = Path.join(ctx.origin, "hooks/post-receive")
      File.write!(hook, "#!/bin/sh\ngit update-ref -d refs/heads/main\n")
      File.chmod!(hook, 0o755)

      log =
        capture_log(fn ->
          assert {:error, {:roadmap_push_unverified, "main", _reason}} =
                   Roadmap.mark_in_progress("2", project: ctx.project)
        end)

      assert log =~ "harness roadmap durable: commit did not land on main"
      {heads, 0} = System.cmd("git", ["-C", ctx.repo, "ls-remote", "--heads", "origin", "main"], stderr_to_stdout: true)
      refute heads =~ "in_progress"
      assert String.trim(heads) == ""
    end

    test "interleaved transitions both land — neither clobbers the other's edit", ctx do
      assert {:ok, _output} = Roadmap.mark_in_progress("2", project: ctx.project)
      assert {:ok, _output} = Roadmap.mark_blocked("3", project: ctx.project, reason: "waiting on upstream")

      # The second transition fetched + rebased onto the first's commit, so both
      # survive on origin/main — the lost-write the durability fix prevents.
      assert origin_task_status(ctx.repo, "2") == "in_progress"
      assert origin_task_status(ctx.repo, "3") == "blocked"

      log = origin_log(ctx.repo)
      assert log =~ "roadmap: task 2 -> in_progress"
      assert log =~ "roadmap: task 3 -> blocked"
    end

    test "a no-op transition (already in that state) commits and pushes nothing", ctx do
      assert {:ok, _output} = Roadmap.mark_in_progress("2", project: ctx.project)
      tip_before = origin_tip(ctx.repo)

      # Re-marking the same status is an rmap no-op: no file change, so nothing
      # to commit or push — the target tip stays put.
      assert {:ok, _output} = Roadmap.mark_in_progress("2", project: ctx.project)
      assert origin_tip(ctx.repo) == tip_before
    end

    test "a project without a target_branch falls back to a local write, not a push", ctx do
      local = %{ctx.project | target_branch: nil}
      tip_before = origin_tip(ctx.repo)

      assert {:ok, _output} = Roadmap.mark_in_progress("2", project: local)

      # No push happened; the local on-disk copy was mutated instead.
      assert origin_tip(ctx.repo) == tip_before
      assert File.read!(Path.join(ctx.repo, "roadmap/tasks.toml")) =~ "in_progress"
    end

    test "mark_landed commits a split roadmap in its repository and leaves the source untouched", ctx do
      %{repo: source_repo} = GitFixture.init_with_origin(name: "durable-source")
      source_tip = origin_tip(source_repo)
      source_head = local_tip(source_repo)
      source_worktrees = worktrees(source_repo)

      project =
        ctx.project
        |> Map.put(:source, {:local, source_repo})
        |> Map.replace!(:roadmap_target_branch, "main")
        |> Map.replace!(:target_branch, "code-release")

      assert {:ok, _output} =
               Roadmap.mark_landed("2",
                 project: project,
                 sha: "0123456789abcdef0123456789abcdef01234567",
                 verified_by: "codex",
                 implemented: "Split-repository roadmap write"
               )

      assert origin_task_status(ctx.repo, "2") == "done"
      assert local_task_status(ctx.repo, "2") == "done"
      assert origin_log(ctx.repo) =~ "roadmap: task 2 -> done (shipped 0123456789ab)"
      assert origin_tip(source_repo) == source_tip
      assert local_tip(source_repo) == source_head
      assert worktrees(source_repo) == source_worktrees
      assert GitFixture.git!(source_repo, ["status", "--porcelain"]) == ""
      refute origin_log(source_repo) =~ "roadmap: task"
    end

    test "a split roadmap without an explicit roadmap branch falls back to a local write", ctx do
      %{repo: source_repo} = GitFixture.init_with_origin(name: "durable-source-no-roadmap-target")
      roadmap_tip = origin_tip(ctx.repo)
      source_tip = origin_tip(source_repo)
      project = %{ctx.project | source: {:local, source_repo}}

      assert {:ok, _output} = Roadmap.mark_in_progress("2", project: project)

      assert local_task_status(ctx.repo, "2") == "in_progress"
      assert origin_tip(ctx.repo) == roadmap_tip
      assert origin_tip(source_repo) == source_tip
      refute origin_log(source_repo) =~ "roadmap: task"
    end

    test "a roadmap path outside git falls back to a local write", ctx do
      roadmap_root = GitFixture.tmp_base(name: "durable-non-git-roadmap")
      File.mkdir_p!(roadmap_root)
      File.cp_r!(Path.join(ctx.repo, "roadmap"), Path.join(roadmap_root, "roadmap"))
      File.cp!(Path.join(ctx.repo, "ROADMAP.md"), Path.join(roadmap_root, "ROADMAP.md"))
      source_tip = origin_tip(ctx.repo)

      project =
        ctx.project
        |> Map.put(:roadmap_path, roadmap_root)
        |> Map.replace!(:roadmap_target_branch, "main")

      assert {:ok, _output} = Roadmap.mark_in_progress("2", project: project)

      assert local_task_status(roadmap_root, "2") == "in_progress"
      assert origin_tip(ctx.repo) == source_tip
    end
  end

  describe "Durable.commit/3 — non-ff retry" do
    test "re-fetches, replays the mutation, and retries instead of force-pushing", ctx do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      apply_fun = fn root ->
        attempt = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        # On the first attempt a competing writer lands first, so our ff-push is
        # rejected non-ff and the loop must re-fetch + replay onto its tip.
        if attempt == 0, do: competing_push(ctx.origin)
        rmap_status(root, ["2", "in_progress"])
      end

      assert {:ok, _output} =
               Durable.commit(ctx.repo, "main",
                 message: "roadmap: task 2 -> in_progress",
                 apply: apply_fun
               )

      # Replayed at least once (attempt 0 lost the race, attempt 1 won).
      assert Agent.get(counter, & &1) >= 2
      # Our transition landed AND the competitor's commit survived — proof the
      # retry rebased rather than force-pushing over the winner.
      assert origin_task_status(ctx.repo, "2") == "in_progress"
      assert origin_log(ctx.repo) =~ "competing change"
    end

    test "surfaces an error after exhausting the retry cap, never force-pushing", ctx do
      # Every attempt loses the race (a fresh competitor each time), so the push
      # is non-ff on every try and the cap is hit.
      apply_fun = fn root ->
        competing_push(ctx.origin)
        rmap_status(root, ["2", "in_progress"])
      end

      assert {:error, {:roadmap_push_exhausted, "main", 2}} =
               Durable.commit(ctx.repo, "main",
                 message: "roadmap: task 2 -> in_progress",
                 apply: apply_fun,
                 max_attempts: 2
               )
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  @spec rmap_status(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  defp rmap_status(root, status_args) do
    args = ["status" | status_args] ++ ["--tasks-path", Path.join(root, "roadmap/tasks.toml")]

    case System.cmd("rmap", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {code, output}}
    end
  end

  # A second clone of `origin` lands an unrelated commit on main first, forcing a
  # non-ff rejection for any writer that based its push on the prior tip.
  defp competing_push(origin) do
    clone = Path.join(System.tmp_dir!(), "durable-compete-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(clone) end)

    {_out, 0} = System.cmd("git", ["clone", "-q", origin, clone], stderr_to_stdout: true)
    GitFixture.git!(clone, ["config", "user.email", "compete@example.com"])
    GitFixture.git!(clone, ["config", "user.name", "Competitor"])
    File.write!(Path.join(clone, "competing-#{System.unique_integer([:positive])}.txt"), "x\n")
    GitFixture.git!(clone, ["add", "."])
    GitFixture.git!(clone, ["commit", "-q", "-m", "competing change"])
    GitFixture.git!(clone, ["push", "-q", "origin", "main"])
    :ok
  end

  # Reads task `id`'s status from roadmap/tasks.toml as it exists on origin/main,
  # via rmap so the assertion is contract-accurate rather than TOML-string-shaped.
  defp origin_task_status(repo, id) do
    repo |> origin_task(id) |> Map.fetch!("status")
  end

  defp origin_task(repo, id) do
    toml = origin_show(repo, "roadmap/tasks.toml")
    path = Path.join(System.tmp_dir!(), "durable-verify-#{System.unique_integer([:positive])}.toml")
    File.write!(path, toml)
    on_exit(fn -> File.rm(path) end)

    {out, 0} = System.cmd("rmap", ["show", id, "--json", "--tasks-path", path], stderr_to_stdout: true)
    JSON.decode!(out)
  end

  # Reads task `id`'s status from the operator clone's on-disk roadmap/tasks.toml
  # (the working copy), to assert the post-push local fast-forward landed.
  defp local_task_status(repo, id) do
    path = Path.join(repo, "roadmap/tasks.toml")
    {out, 0} = System.cmd("rmap", ["show", id, "--json", "--tasks-path", path], stderr_to_stdout: true)
    out |> JSON.decode!() |> Map.fetch!("status")
  end

  defp origin_show(repo, file) do
    GitFixture.git!(repo, ["fetch", "-q", "origin", "main"])
    GitFixture.git!(repo, ["show", "origin/main:#{file}"])
  end

  defp origin_log(repo) do
    GitFixture.git!(repo, ["fetch", "-q", "origin", "main"])
    GitFixture.git!(repo, ["log", "--format=%s", "origin/main"])
  end

  defp origin_tip(repo) do
    GitFixture.git!(repo, ["fetch", "-q", "origin", "main"])
    repo |> GitFixture.git!(["rev-parse", "origin/main"]) |> String.trim()
  end

  defp local_tip(repo) do
    repo |> GitFixture.git!(["rev-parse", "HEAD"]) |> String.trim()
  end

  defp worktrees(repo) do
    GitFixture.git!(repo, ["worktree", "list", "--porcelain"])
  end
end
