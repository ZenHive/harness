defmodule Harness.AgentAdapter.WatchdogTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Watchdog

  describe "blocked_command/2" do
    test "blocks mix deps.clean" do
      assert {:blocked_command, "mix deps.clean --all"} = Watchdog.blocked_command("mix deps.clean --all", "/tmp/work")
    end

    test "blocks force pushes" do
      assert {:blocked_command, "git push --force origin HEAD:main"} =
               Watchdog.blocked_command("git push --force origin HEAD:main", "/tmp/work")
    end

    test "blocks recursive forced removal outside the worktree" do
      worktree = "/Users/dev/worktrees/run-1"

      assert {:blocked_command, "rm -rf /Users/dev/elsewhere"} =
               Watchdog.blocked_command("rm -rf /Users/dev/elsewhere", worktree)

      assert {:blocked_command, "rm -rf /Users/dev/important"} =
               Watchdog.blocked_command("rm -rf /Users/dev/important", worktree)

      assert nil == Watchdog.blocked_command("rm -rf tmp/build", worktree)
    end

    test "allows recursive removal of OS temp scratch" do
      worktree = "/Users/dev/worktrees/run-1"
      tmp_sub = Path.join(System.tmp_dir!(), "harness_results_test")

      assert nil == Watchdog.blocked_command("rm -rf #{tmp_sub} && echo cleared", worktree)
      assert nil == Watchdog.blocked_command("rm -rf /tmp/gtlocktest", worktree)
      assert {:blocked_command, _} = Watchdog.blocked_command("rm -rf /tmp", worktree)
    end

    test "does not sweep a later command's path token as an rm target" do
      worktree = "/Users/dev/worktrees/run-1"

      command =
        "cd /tmp && rm -rf gtlocktest && mkdir gtlocktest && " <>
          "git worktree add -q ../gtlock_wt -b wtbranch; cd /tmp && rm -rf gtlocktest gtlock_wt"

      assert nil == Watchdog.blocked_command(command, worktree)
    end

    test "does not block edits to the former grader or CI config paths" do
      assert nil == Watchdog.blocked_command("apply_patch lib/harness/verification.ex", "/tmp/work")
      assert nil == Watchdog.blocked_command("sed -i '' 's/x/y/' .github/workflows/ci.yml", "/tmp/work")
    end
  end

  describe "wait/1" do
    test "returns the soonest deadline when all three are set" do
      now = System.monotonic_time(:millisecond)

      watchdog = %Watchdog{
        total_deadline: now + 10_000,
        idle_timeout: 5_000,
        idle_deadline: now + 5_000,
        progress_timeout: 3_000,
        progress_deadline: now + 3_000,
        worktree_path: "/tmp/work",
        edit_fingerprint: nil
      }

      wait = Watchdog.wait(watchdog)
      assert wait > 2_000 and wait <= 3_000
    end

    test "ignores a nil progress deadline" do
      now = System.monotonic_time(:millisecond)

      watchdog = %Watchdog{
        total_deadline: now + 10_000,
        idle_timeout: 4_000,
        idle_deadline: now + 4_000,
        progress_timeout: nil,
        progress_deadline: nil,
        worktree_path: "/tmp/work",
        edit_fingerprint: nil
      }

      wait = Watchdog.wait(watchdog)
      assert wait > 3_000 and wait <= 4_000
    end
  end
end
