defmodule Harness.Run.CheckoutPollutionRecoveryTest do
  use Harness.RunCase, async: true

  describe "bounded AI recovery seam — checkout pollution" do
    test "repaired checkout pollution resumes through the reviewer gate" do
      repo = GitFixture.init_repo()

      result =
        run(
          project: ProjectFixture.from_repo(repo),
          checkout_pollution_check: true,
          adapter_opts: [command: {:write_and_pollute_checkout, repo}],
          reviewer_adapter_opts: [command: {:review, "approve"}, recovery_command: :recovery_clean]
        )

      assert %Result{state: :done, reason: :approved} = result
      assert %Review{verdict: :approve} = result.review
      assert result.recovery_attempts == 1
      assert result.recovery_outcome == :repaired
      assert result.recovery_repaired == "removed leaked.txt"
      assert %TokenUsage{} = result.recovery_token_usage
      assert GitFixture.git!(repo, ["status", "--porcelain"]) == ""
    end

    test "dead checkout pollution settles failed with recovery witness fields" do
      repo = GitFixture.init_repo()

      result =
        run(
          project: ProjectFixture.from_repo(repo),
          checkout_pollution_check: true,
          adapter_opts: [command: {:write_and_pollute_checkout, repo}],
          reviewer_adapter_opts: [command: {:review, "approve"}, recovery_command: :recovery_dead]
        )

      assert %Result{state: :failed, reason: {:checkout_polluted, status}} = result
      assert status =~ "leaked.txt"
      assert result.review == nil
      assert result.recovery_attempts == 1
      assert result.recovery_outcome == :dead
      assert result.recovery_repaired == nil
      assert %TokenUsage{} = result.recovery_token_usage
      assert File.dir?(result.worktree_path)
    end

    @tag :capture_log
    test "driver crash with checkout pollution routes through recovery before the reviewer gate" do
      repo = GitFixture.init_repo()

      result =
        run(
          project: ProjectFixture.from_repo(repo),
          adapter: PollutingCrashAdapter,
          checkout_pollution_check: true,
          adapter_opts: [repo: repo],
          reviewer_adapter_opts: [command: {:review, "approve"}, recovery_command: :recovery_clean]
        )

      assert %Result{state: :done, reason: :approved} = result
      assert %Review{verdict: :approve} = result.review
      assert result.recovery_attempts == 1
      assert result.recovery_outcome == :repaired
      assert GitFixture.git!(repo, ["status", "--porcelain"]) == ""
    end

    test "per-run recovery budget exhaustion fails honestly without spawning recovery" do
      repo = GitFixture.init_repo()

      result =
        run(
          project: ProjectFixture.from_repo(repo),
          checkout_pollution_check: true,
          recovery_budget: 0,
          adapter_opts: [command: {:write_and_pollute_checkout, repo}],
          reviewer_adapter_opts: [command: {:review, "approve"}, recovery_command: :recovery_clean]
        )

      assert %Result{state: :failed, reason: {:checkout_polluted, status}} = result
      assert status =~ "leaked.txt"
      assert result.recovery_attempts == 0
      assert result.recovery_outcome == nil
      assert result.review == nil
    end

    test "reviewer reject bypasses recovery" do
      result =
        run(
          recovery_budget: 1,
          reviewer_adapter_opts: [command: {:review, "reject"}, recovery_command: :recovery_clean]
        )

      assert %Result{state: :failed, reason: {:review_rejected, report}} = result
      assert report == FakeAdapter.review_report("reject")
      assert result.recovery_attempts == 0
      assert result.recovery_outcome == nil
    end
  end
end
