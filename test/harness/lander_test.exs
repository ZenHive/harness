defmodule Harness.LanderTest do
  use ExUnit.Case, async: false

  alias Harness.CheckStack
  alias Harness.GitFixture
  alias Harness.Lander
  alias Harness.Project
  alias Harness.Verification.Check
  alias Harness.Verification.Verdict

  @moduletag :tmp_dir

  # ── git fixture: a bare `origin` + a working clone, so the lander's
  #    ff-push to `origin/<target>` is real and assertable. ──────────────

  defp git(repo, args), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp sha(repo, ref), do: repo |> GitFixture.git!(["rev-parse", ref]) |> String.trim()

  defp ancestor?(repo, maybe_ancestor, descendant) do
    {_output, status} = git(repo, ["merge-base", "--is-ancestor", maybe_ancestor, descendant])
    status == 0
  end

  defp pass_stack, do: [%CheckStack{name: :test, checks: [%Check{name: "ok", command: "true", args: []}], workdir: ""}]
  defp fail_stack, do: [%CheckStack{name: :test, checks: [%Check{name: "no", command: "false", args: []}], workdir: ""}]

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
      check_stacks: pass_stack(),
      roadmap_path: tmp_dir,
      target_branch: "main"
    }

    request = %{project: project, run_id: "run-x", task_id: "1", agent: :claude, branch: "harness/run-x"}

    %{origin: origin, repo: repo, base_sha: base_sha, branch_tip: branch_tip, project: project, request: request}
  end

  describe "land/1 — fast-forward path (target unmoved)" do
    test "pushes the branch tip to origin/<target> and re-verifies green", ctx do
      assert {:landed, landed} = Lander.land(ctx.request)
      assert landed == ctx.branch_tip
      assert sha(ctx.origin, "refs/heads/main") == ctx.branch_tip
    end
  end

  describe "land/1 — rebase path (target moved under the branch)" do
    test "rebases onto origin/<target>, re-verifies, then ff-pushes", ctx do
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

  describe "land/1 — integrated state re-verified before the merge is kept" do
    test "a red post-integration verdict aborts the land and retains the branch", ctx do
      request = %{ctx.request | project: %{ctx.project | check_stacks: fail_stack()}}

      assert {:post_merge_red, %Verdict{}} = Lander.land(request)
      # origin/<target> never advanced; the branch is retained for inspection.
      assert sha(ctx.origin, "refs/heads/main") == ctx.base_sha
      assert sha(ctx.repo, "harness/run-x") == ctx.branch_tip
    end
  end

  describe "land/1 — conflict on rebase (Task 101 seam)" do
    test "surfaces {:conflict, _} and leaves origin/<target> untouched", ctx do
      # conflicting edit on the branch...
      GitFixture.git!(ctx.repo, ["checkout", "harness/run-x"])
      File.write!(Path.join(ctx.repo, "README.md"), "branch side\n")
      GitFixture.git!(ctx.repo, ["add", "."])
      GitFixture.git!(ctx.repo, ["commit", "-m", "branch readme"])
      GitFixture.git!(ctx.repo, ["checkout", "main"])

      # ...and a conflicting edit on main, pushed to origin.
      File.write!(Path.join(ctx.repo, "README.md"), "main side\n")
      GitFixture.git!(ctx.repo, ["add", "."])
      GitFixture.git!(ctx.repo, ["commit", "-m", "main readme"])
      GitFixture.git!(ctx.repo, ["push", "origin", "main"])
      moved_main = sha(ctx.origin, "refs/heads/main")

      assert {:conflict, _output} = Lander.land(ctx.request)
      assert sha(ctx.origin, "refs/heads/main") == moved_main
    end
  end

  describe "land/1 — guards" do
    test "skips a {:github, _} source it cannot push to", ctx do
      gh = %Project{
        name: "gh",
        source: {:github, "https://example.com/x.git"},
        check_stacks: pass_stack(),
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
end
