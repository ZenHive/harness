defmodule Harness.LanderTest do
  use ExUnit.Case, async: false

  alias Harness.GitFixture
  alias Harness.Lander
  alias Harness.Notification.Event
  alias Harness.Project
  alias Harness.Run.LogRecord

  @moduletag :tmp_dir

  # ── git fixture: a bare `origin` + a working clone, so the lander's
  #    ff-push to `origin/<target>` is real and assertable. ──────────────

  defp git(repo, args), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp sha(repo, ref), do: repo |> GitFixture.git!(["rev-parse", ref]) |> String.trim()

  defp ancestor?(repo, maybe_ancestor, descendant) do
    {_output, status} = git(repo, ["merge-base", "--is-ancestor", maybe_ancestor, descendant])
    status == 0
  end

  setup %{tmp_dir: tmp_dir} do
    %{origin: origin, repo: repo} = GitFixture.init_with_origin()

    base_sha = sha(repo, "HEAD")

    # the settled run's deliverable: harness/<run-id> with one extra commit.
    GitFixture.git!(repo, ["checkout", "-b", "harness/run-x"])
    File.write!(Path.join(repo, "feature.txt"), "work\n")
    GitFixture.git!(repo, ["add", "."])
    GitFixture.git!(repo, ["commit", "-m", "agent work"])
    branch_tip = sha(repo, "HEAD")
    # leave HEAD on main so the branch is free for checkout_existing.
    GitFixture.git!(repo, ["checkout", "main"])

    project = %Project{
      name: "demo",
      source: {:local, repo},
      roadmap_path: tmp_dir,
      target_branch: "main"
    }

    request = %{
      project: project,
      run_id: "run-x",
      task_id: "1",
      agent: :claude,
      reviewer: :codex,
      branch: "harness/run-x"
    }

    %{origin: origin, repo: repo, base_sha: base_sha, branch_tip: branch_tip, project: project, request: request}
  end

  describe "land/1 — fast-forward path (target unmoved)" do
    test "pushes the branch tip to origin/<target>", ctx do
      assert {:landed, landed} = Lander.land(ctx.request)
      assert landed == ctx.branch_tip
      assert sha(ctx.origin, "refs/heads/main") == ctx.branch_tip
    end
  end

  describe "land/1 — post-push local target sync" do
    test "fast-forwards local target ref without touching the checkout when operator is off target", ctx do
      GitFixture.git!(ctx.repo, ["checkout", "-b", "side"])
      side_head = sha(ctx.repo, "HEAD")

      assert {:landed, landed} = Lander.land(ctx.request)

      assert landed == ctx.branch_tip
      assert sha(ctx.repo, "main") == landed
      assert sha(ctx.repo, "HEAD") == side_head
      assert String.trim(GitFixture.git!(ctx.repo, ["branch", "--show-current"])) == "side"
      refute File.exists?(Path.join(ctx.repo, "feature.txt"))
    end

    test "fast-forwards HEAD when operator is on target with a clean tree", ctx do
      assert String.trim(GitFixture.git!(ctx.repo, ["branch", "--show-current"])) == "main"

      assert {:landed, landed} = Lander.land(ctx.request)

      assert landed == ctx.branch_tip
      assert sha(ctx.repo, "HEAD") == landed
      assert File.read!(Path.join(ctx.repo, "feature.txt")) == "work\n"
    end

    test "skips and notifies when operator is on target with a dirty tree", ctx do
      put_capture_sink()
      File.write!(Path.join(ctx.repo, "scratch.txt"), "local\n")

      assert {:landed, landed} = Lander.land(ctx.request)

      assert landed == ctx.branch_tip
      assert sha(ctx.repo, "HEAD") == ctx.base_sha
      assert File.read!(Path.join(ctx.repo, "scratch.txt")) == "local\n"
      assert_receive {:notify, %Event{type: :local_sync_skipped, outcome: reason}}
      assert reason =~ "local main behind origin by 1"
      assert reason =~ "sync manually"
    end

    test "leaves a non-ff local target untouched and notifies instead of forcing it", ctx do
      put_capture_sink()
      File.write!(Path.join(ctx.repo, "local.txt"), "operator\n")
      GitFixture.git!(ctx.repo, ["add", "."])
      GitFixture.git!(ctx.repo, ["commit", "-m", "operator work"])
      local_head = sha(ctx.repo, "HEAD")

      assert {:landed, landed} = Lander.land(ctx.request)

      assert landed == ctx.branch_tip
      assert sha(ctx.origin, "refs/heads/main") == landed
      assert sha(ctx.repo, "HEAD") == local_head
      assert File.read!(Path.join(ctx.repo, "local.txt")) == "operator\n"
      assert_receive {:notify, %Event{type: :local_sync_skipped, outcome: reason}}
      assert reason =~ "local main behind origin by 1"
      assert reason =~ "sync manually"
    end
  end

  describe "land/1 — rebase path (target moved under the branch)" do
    test "rebases onto origin/<target>, then ff-pushes", ctx do
      # advance origin/main past the branch's fork point (non-conflicting file).
      File.write!(Path.join(ctx.repo, "main_moved.txt"), "x\n")
      GitFixture.git!(ctx.repo, ["add", "."])
      GitFixture.git!(ctx.repo, ["commit", "-m", "main moves"])
      GitFixture.git!(ctx.repo, ["push", "origin", "main"])
      moved_main = sha(ctx.origin, "refs/heads/main")
      GitFixture.git!(ctx.repo, ["checkout", "main"])

      assert {:landed, landed} = Lander.land(ctx.request)
      # the landed tip is the rebased branch, not the pre-rebase tip.
      refute landed == ctx.branch_tip
      assert sha(ctx.origin, "refs/heads/main") == landed
      # integrated history contains BOTH the moved-main commit and the agent work.
      assert ancestor?(ctx.origin, moved_main, "refs/heads/main")
      {_out, 0} = git(ctx.origin, ["cat-file", "-e", landed <> ":feature.txt"])
    end
  end

  describe "land/1 — post-merge audit trigger" do
    test "a successful land enqueues one audit job carrying the pre-land target tip", ctx do
      test_pid = self()

      Application.put_env(:harness, :oban_insert, fn changeset ->
        job = Ecto.Changeset.apply_action!(changeset, :insert)
        send(test_pid, {:audit_insert, job})
        {:ok, job}
      end)

      on_exit(fn -> Application.delete_env(:harness, :oban_insert) end)

      assert {:landed, _landed} = Lander.land(ctx.request)

      assert_receive {:audit_insert, %Oban.Job{args: args, worker: "Harness.Audit.Worker", queue: "audit"}}

      assert args == %{
               "project_name" => "demo",
               "base_sha" => ctx.base_sha,
               "implementer" => "claude",
               "reviewer" => "codex"
             }
    end
  end

  describe "land/1 — conflict on rebase (Task 189: merge-resolver agent)" do
    # Stages a real rebase conflict on README.md: the branch and origin/main
    # both edit it from a shared base. Returns the moved-main sha for assertions.
    defp stage_conflict(ctx) do
      GitFixture.git!(ctx.repo, ["checkout", "harness/run-x"])
      File.write!(Path.join(ctx.repo, "README.md"), "branch side\n")
      GitFixture.git!(ctx.repo, ["add", "."])
      GitFixture.git!(ctx.repo, ["commit", "-m", "branch readme"])
      GitFixture.git!(ctx.repo, ["checkout", "main"])

      File.write!(Path.join(ctx.repo, "README.md"), "main side\n")
      GitFixture.git!(ctx.repo, ["add", "."])
      GitFixture.git!(ctx.repo, ["commit", "-m", "main readme"])
      GitFixture.git!(ctx.repo, ["push", "origin", "main"])
      sha(ctx.origin, "refs/heads/main")
    end

    defp put_resolver(fun) do
      Application.put_env(:harness, :lander_resolver, fun)
      on_exit(fn -> Application.delete_env(:harness, :lander_resolver) end)
    end

    test "a resolver that reconciles the markers lands both sides", ctx do
      moved_main = stage_conflict(ctx)

      # The injected resolver edits the open landing worktree to keep BOTH sides
      # (exactly what a real merge-resolver agent would do), leaving no markers.
      put_resolver(fn %{path: path}, _opts ->
        File.write!(Path.join(path, "README.md"), "main side\nbranch side\n")
        :ok
      end)

      assert {:landed, landed} = Lander.land(ctx.request)
      # the conflict was resolved + continued, then ff-pushed.
      assert sha(ctx.origin, "refs/heads/main") == landed
      assert ancestor?(ctx.origin, moved_main, "refs/heads/main")
      {readme, 0} = git(ctx.origin, ["show", landed <> ":README.md"])
      assert readme =~ "main side"
      assert readme =~ "branch side"
    end

    test "a resolver that leaves conflict markers NEVER lands — falls back to {:conflict, _}", ctx do
      moved_main = stage_conflict(ctx)

      # The agent "ran" but left a marker behind; the mechanical gate must catch
      # it, abort the rebase, and fall back rather than land a poisoned tree.
      put_resolver(fn %{path: path}, _opts ->
        File.write!(Path.join(path, "README.md"), "<<<<<<< HEAD\nmain side\n=======\nbranch side\n>>>>>>> x\n")
        :ok
      end)

      assert {:conflict, _output} = Lander.land(ctx.request)
      assert sha(ctx.origin, "refs/heads/main") == moved_main
    end

    test "an unavailable/declining resolver falls back to {:conflict, _}, origin untouched", ctx do
      moved_main = stage_conflict(ctx)
      put_resolver(fn _worktree, _opts -> {:error, :no_resolver} end)

      assert {:conflict, _output} = Lander.land(ctx.request)
      assert sha(ctx.origin, "refs/heads/main") == moved_main
    end
  end

  describe "land/1 — guards" do
    test "skips a {:github, _} source it cannot push to", ctx do
      gh = %Project{
        name: "gh",
        source: {:github, "https://example.com/x.git"},
        roadmap_path: ctx.request.project.roadmap_path,
        target_branch: "main"
      }

      assert {:skipped, :github_source} = Lander.land(%{ctx.request | project: gh})
    end

    test "errors when the project declares no target_branch", ctx do
      request = %{ctx.request | project: %{ctx.project | target_branch: nil}}
      assert {:error, :no_target_branch} = Lander.land(request)
    end
  end

  describe "enqueue/1 + landing_args/2 (operator Re-land)" do
    test "landing_args/2 reconstructs the landing job from a persisted record" do
      record = %LogRecord{
        batch_id: "b",
        run_id: "run-abc",
        task_id: "42",
        adapter: Harness.AgentAdapter.Claude,
        state: :done,
        reason: :approved,
        duration_ms: 1,
        agent: :claude
      }

      project = %Project{name: "demo", source: {:local, "/tmp/x"}, roadmap_path: "/tmp", target_branch: "main"}

      assert Lander.landing_args(record, project) == %{
               "project_name" => "demo",
               "run_id" => "run-abc",
               "task_id" => "42",
               "agent" => "claude",
               "reviewer" => nil,
               "branch" => "harness/run-abc",
               "land_attempt" => 1
             }
    end

    test "enqueue/1 returns :not_found for an unrecorded run_id" do
      assert {:error, :not_found} = Lander.enqueue("__no_such_run__")
    end
  end

  defp put_capture_sink do
    Application.put_env(:harness, :notification_sinks, [Harness.Test.CaptureSink])
    Application.put_env(:harness, :test_capture_pid, self())

    on_exit(fn ->
      Application.delete_env(:harness, :notification_sinks)
      Application.delete_env(:harness, :test_capture_pid)
    end)
  end
end
