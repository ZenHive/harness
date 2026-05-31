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

    test "blocks edits to the grader and CI config" do
      assert {:blocked_command, "apply_patch lib/harness/verification.ex"} =
               Reflex.blocked_command("apply_patch lib/harness/verification.ex", "/tmp/work")

      assert {:blocked_command, _} =
               Reflex.blocked_command("sed -i '' 's/x/y/' .github/workflows/ci.yml", "/tmp/work")
    end

    test "allows legitimate dep-adds and config edits" do
      assert nil == Reflex.blocked_command("apply_patch mix.exs", "/tmp/work")
      assert nil == Reflex.blocked_command("sed -i '' 's/x/y/' config/runtime.exs", "/tmp/work")
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
