defmodule Harness.Run.ReflexTest do
  use ExUnit.Case, async: true

  alias Harness.GitFixture
  alias Harness.Run.Reflex

  describe "blocked_command/2" do
    test "blocks mix deps.clean" do
      assert {:blocked_command, "mix deps.clean --all"} = Reflex.blocked_command("mix deps.clean --all", "/tmp/work")
    end

    test "blocks force pushes" do
      assert {:blocked_command, "git push --force origin HEAD:main"} =
               Reflex.blocked_command("git push --force origin HEAD:main", "/tmp/work")
    end

    test "blocks recursive forced removal outside the worktree" do
      worktree = "/tmp/harness-worktree"

      assert {:blocked_command, "rm -rf /tmp/elsewhere"} = Reflex.blocked_command("rm -rf /tmp/elsewhere", worktree)
      assert nil == Reflex.blocked_command("rm -rf tmp/build", worktree)
    end

    test "does not block edits to the former grader or CI config paths" do
      assert nil == Reflex.blocked_command("apply_patch lib/harness/verification.ex", "/tmp/work")
      assert nil == Reflex.blocked_command("sed -i '' 's/x/y/' .github/workflows/ci.yml", "/tmp/work")
    end
  end

  describe "wait/1" do
    test "returns the soonest deadline when all three are set" do
      now = System.monotonic_time(:millisecond)

      reflex = %Reflex{
        total_deadline: now + 10_000,
        idle_timeout: 5_000,
        idle_deadline: now + 5_000,
        progress_timeout: 3_000,
        progress_deadline: now + 3_000,
        worktree_path: "/tmp/work",
        edit_fingerprint: nil
      }

      # Soonest of the three (progress at ~3s) bounds the wait; allow slack for
      # the monotonic read inside wait/1.
      wait = Reflex.wait(reflex)
      assert wait > 2_000 and wait <= 3_000
    end

    test "ignores a nil progress deadline" do
      now = System.monotonic_time(:millisecond)

      reflex = %Reflex{
        total_deadline: now + 10_000,
        idle_timeout: 4_000,
        idle_deadline: now + 4_000,
        progress_timeout: nil,
        progress_deadline: nil,
        worktree_path: "/tmp/work",
        edit_fingerprint: nil
      }

      wait = Reflex.wait(reflex)
      assert wait > 3_000 and wait <= 4_000
    end
  end

  describe "checkout porcelain guard" do
    test "delegates main-checkout pollution to the reflex layer" do
      repo = GitFixture.init_repo()
      {:ok, snapshot} = Reflex.checkout_snapshot(repo)
      File.write!(Path.join(repo, "leaked.txt"), "outside")

      assert {:checkout_polluted, polluted} = Reflex.checkout_pollution_reason(repo, snapshot, [])
      assert polluted =~ "leaked.txt"
    end
  end
end
