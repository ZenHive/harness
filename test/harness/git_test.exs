defmodule Harness.GitTest do
  use ExUnit.Case, async: true

  alias Harness.Git
  alias Harness.GitFixture

  @moduletag :tmp_dir
  @git_push_failed 1
  @git_push_ok 0

  describe "non_fast_forward?/5 — deterministic ancestry signal" do
    setup do
      # A bare origin + working clone, both at the same `main` tip. Tests then
      # drive divergence by landing a competing commit on origin directly.
      %{origin: origin, repo: repo} = GitFixture.init_with_origin()
      {:ok, origin: origin, repo: repo}
    end

    test "the remote advanced under us -> true (ancestry, not English match)", %{origin: origin, repo: repo} do
      compete(origin)

      # `repo`'s HEAD is still the pre-competitor tip, so the current remote tip
      # is no longer an ancestor of it. The push output is empty on purpose:
      # the verdict comes from the ancestry check, not the text.
      assert Git.non_fast_forward?(repo, "HEAD", "main", @git_push_failed, "")
    end

    test "the lander's call shape (an explicit tip sha) is handled too", %{origin: origin, repo: repo} do
      tip = repo |> GitFixture.git!(["rev-parse", "HEAD"]) |> String.trim()
      compete(origin)

      assert Git.non_fast_forward?(repo, tip, "main", @git_push_failed, "")
    end

    test "the remote is still an ancestor (a non-ff failure it is NOT) -> false", %{repo: repo} do
      # Advance only the local clone, leaving origin/main behind. The remote tip
      # IS an ancestor of HEAD, so this is fast-forwardable — the deterministic
      # signal must NOT classify it as non-fast-forward even on rejection text.
      File.write!(Path.join(repo, "local.txt"), "ahead\n")
      GitFixture.git!(repo, ["add", "local.txt"])
      GitFixture.git!(repo, ["commit", "-q", "-m", "local ahead"])

      refute Git.non_fast_forward?(
               repo,
               "HEAD",
               "main",
               @git_push_failed,
               "! [rejected] main -> main (non-fast-forward)"
             )
    end

    test "a successful push status is never classified as rejected", %{repo: repo} do
      refute Git.non_fast_forward?(
               repo,
               "HEAD",
               "main",
               @git_push_ok,
               "! [rejected] main -> main (non-fast-forward)"
             )
    end
  end

  describe "non_fast_forward?/5 — English fallback when inconclusive" do
    setup do
      # No remote configured, so the refresh fetch fails and the predicate must
      # fall back to matching git's rejection text.
      repo = GitFixture.init_repo()
      {:ok, repo: repo}
    end

    test "rejection text matches -> true", %{repo: repo} do
      assert Git.non_fast_forward?(repo, "HEAD", "main", @git_push_failed, "! [rejected] main (fetch first)")

      assert Git.non_fast_forward?(
               repo,
               "HEAD",
               "main",
               @git_push_failed,
               "Updates were rejected because ... non-fast-forward"
             )
    end

    test "an unrelated failure (no rejection text) -> false", %{repo: repo} do
      refute Git.non_fast_forward?(repo, "HEAD", "main", @git_push_failed, "fatal: Authentication failed for 'origin'")
    end
  end

  # Lands an unrelated commit on `origin/main` from a throwaway clone, so any
  # writer still based on the prior tip is now behind — a real non-ff condition.
  @spec compete(String.t()) :: :ok
  defp compete(origin) do
    clone = Path.join(System.tmp_dir!(), "git-compete-#{System.unique_integer([:positive])}")
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
end
