defmodule Harness.Run.WorktreeIsolationTest do
  use Harness.RunCase, async: true

  describe "worktree isolation" do
    test "branches a targeted project from origin target even when local HEAD is stale" do
      %{origin: origin, repo: repo} = GitFixture.init_with_origin()
      base = GitFixture.tmp_base()
      stale_sha = String.trim(GitFixture.git!(repo, ["rev-parse", "HEAD"]))

      File.write!(Path.join(repo, "landed.txt"), "landed upstream\n")
      GitFixture.git!(repo, ["add", "landed.txt"])
      GitFixture.git!(repo, ["commit", "-q", "-m", "landed upstream"])
      GitFixture.git!(repo, ["push", "-q", "origin", "main"])
      origin_sha = String.trim(GitFixture.git!(origin, ["rev-parse", "main"]))
      GitFixture.git!(repo, ["reset", "--hard", stale_sha])

      project = ProjectFixture.from_repo(repo, target_branch: "main")

      {:ok, run_id, pid} =
        Run.Supervisor.start_run(
          item(),
          project,
          FakeAdapter,
          base |> default_opts() |> Keyword.put(:adapter_opts, command: :echo)
        )

      assert %Result{state: :done, reason: :approved} = await_result(run_id, pid)
      assert String.trim(GitFixture.git!(repo, ["rev-parse", "HEAD"])) == stale_sha
      assert String.trim(GitFixture.git!(repo, ["rev-parse", "harness/#{run_id}"])) == origin_sha
    end

    test "target fetch failure falls back to HEAD and the run still starts" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()
      head_sha = String.trim(GitFixture.git!(repo, ["rev-parse", "HEAD"]))
      project = ProjectFixture.from_repo(repo, target_branch: "main")

      log =
        capture_log(fn ->
          {:ok, run_id, pid} =
            Run.Supervisor.start_run(
              item(),
              project,
              FakeAdapter,
              base |> default_opts() |> Keyword.put(:adapter_opts, command: :echo)
            )

          assert %Result{state: :done, reason: :approved} = await_result(run_id, pid)
          assert String.trim(GitFixture.git!(repo, ["rev-parse", "harness/#{run_id}"])) == head_sha
        end)

      assert log =~ "harness run: failed to fetch origin/main"
      assert log =~ "falling back to HEAD"
    end

    test "projects without a target branch keep the HEAD base behavior" do
      %{origin: origin, repo: repo} = GitFixture.init_with_origin()
      base = GitFixture.tmp_base()
      stale_sha = String.trim(GitFixture.git!(repo, ["rev-parse", "HEAD"]))

      File.write!(Path.join(repo, "landed.txt"), "landed upstream\n")
      GitFixture.git!(repo, ["add", "landed.txt"])
      GitFixture.git!(repo, ["commit", "-q", "-m", "landed upstream"])
      GitFixture.git!(repo, ["push", "-q", "origin", "main"])
      origin_sha = String.trim(GitFixture.git!(origin, ["rev-parse", "main"]))
      GitFixture.git!(repo, ["reset", "--hard", stale_sha])

      project = ProjectFixture.from_repo(repo, target_branch: nil)

      {:ok, run_id, pid} =
        Run.Supervisor.start_run(
          item(),
          project,
          FakeAdapter,
          base |> default_opts() |> Keyword.put(:adapter_opts, command: :echo)
        )

      assert %Result{state: :done, reason: :approved} = await_result(run_id, pid)
      assert origin_sha != stale_sha
      assert String.trim(GitFixture.git!(repo, ["rev-parse", "harness/#{run_id}"])) == stale_sha
    end

    test "REGRESSION (Task 66): skips pollution detection for adapters declaring worktree isolation" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()

      {:ok, run_id, pid} =
        Run.Supervisor.start_run(
          item(),
          ProjectFixture.from_repo(repo),
          FakeAdapter,
          base
          |> default_opts()
          |> Keyword.put(:adapter_opts, command: {:write_and_pollute_checkout, repo})
        )

      result = await_result(run_id, pid)

      assert %Result{state: :done, reason: :approved} = result
      assert GitFixture.git!(repo, ["status", "--porcelain"]) =~ "leaked.txt"
    end
  end
end
