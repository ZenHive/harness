defmodule Harness.GitTest do
  use ExUnit.Case, async: false

  alias Harness.Git
  alias Harness.Git.TargetSync
  alias Harness.GitFixture

  @moduletag :tmp_dir
  @git_push_failed 1
  @git_push_ok 0

  describe "fetch_origin/1" do
    test "fetches origin in a clone" do
      %{repo: repo} = GitFixture.init_with_origin()

      assert :ok = Git.fetch_origin(repo)
    end

    test "wraps a failed fetch as {:fetch_failed, reason}" do
      dir = GitFixture.tmp_base(name: "no-origin")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      GitFixture.git!(dir, ["init", "-q"])

      assert {:error, {:fetch_failed, {:git_failed, ["fetch", "origin"], _status, _out}}} =
               Git.fetch_origin(dir)
    end
  end

  describe "TargetSync.ff_local/2" do
    test "returns a conservative skip when the remote branch does not exist" do
      %{repo: repo} = GitFixture.init_with_origin()

      assert {:skipped, reason} = TargetSync.ff_local(repo, "missing-roadmap-branch")
      assert reason =~ "fetch_remote_target_failed"
      assert reason =~ "sync manually"
    end

    test "fast-forwards the local branch ref without touching the checkout when operator is off target" do
      %{origin: origin, repo: repo} = GitFixture.init_with_origin()
      GitFixture.git!(repo, ["checkout", "-b", "side"])
      side_head = rev(repo, "HEAD")
      advance_origin(origin)

      assert :synced = TargetSync.ff_local(repo, "main")

      assert rev(repo, "main") == rev(origin, "refs/heads/main")
      assert rev(repo, "HEAD") == side_head
      assert String.trim(GitFixture.git!(repo, ["branch", "--show-current"])) == "side"
      refute File.exists?(Path.join(repo, "ahead-1.txt"))
    end

    test "fast-forwards HEAD when operator is on target with a clean tree" do
      %{origin: origin, repo: repo} = GitFixture.init_with_origin()
      advance_origin(origin)

      assert String.trim(GitFixture.git!(repo, ["branch", "--show-current"])) == "main"
      assert :synced = TargetSync.ff_local(repo, "main")

      assert rev(repo, "HEAD") == rev(origin, "refs/heads/main")
      assert File.read!(Path.join(repo, "ahead-1.txt")) == "1\n"
    end

    test "skips when operator is on target with a dirty tree" do
      %{origin: origin, repo: repo} = GitFixture.init_with_origin()
      advance_origin(origin)
      local_head = rev(repo, "HEAD")
      File.write!(Path.join(repo, "scratch.txt"), "local\n")

      assert {:skipped, reason} = TargetSync.ff_local(repo, "main")

      assert reason =~ "local main behind origin by 1"
      assert reason =~ "sync manually"
      refute reason =~ "self-host"
      assert rev(repo, "HEAD") == local_head
      assert File.read!(Path.join(repo, "scratch.txt")) == "local\n"
    end

    test "leaves a non-ff local target untouched instead of forcing it" do
      %{origin: origin, repo: repo} = GitFixture.init_with_origin()
      File.write!(Path.join(repo, "local.txt"), "operator\n")
      GitFixture.git!(repo, ["add", "local.txt"])
      GitFixture.git!(repo, ["commit", "-q", "-m", "operator work"])
      local_head = rev(repo, "HEAD")
      advance_origin(origin)

      assert {:skipped, reason} = TargetSync.ff_local(repo, "main")

      assert reason =~ "local main behind origin by 1"
      assert reason =~ "sync manually"
      refute reason =~ "self-host"
      assert rev(repo, "HEAD") == local_head
      assert File.read!(Path.join(repo, "local.txt")) == "operator\n"
    end

    test "drift message reports the origin behind_count" do
      %{origin: origin, repo: repo} = GitFixture.init_with_origin()
      advance_origin(origin, 2)
      File.write!(Path.join(repo, "scratch.txt"), "local\n")

      assert {:skipped, reason} = TargetSync.ff_local(repo, "main")

      assert reason == "local main behind origin by 2; sync manually"
    end

    test "self-host skip names the case and leaves HEAD unmoved" do
      %{origin: origin, repo: repo} = GitFixture.init_with_origin()
      advance_origin(origin)
      stub_node_source_root(repo)
      local_head = rev(repo, "HEAD")

      assert {:skipped, reason} = TargetSync.ff_local(repo, "main")

      assert reason =~ "self-host:"
      assert reason =~ "local main behind origin by 1"
      assert reason =~ "sync manually"
      assert rev(repo, "HEAD") == local_head
      refute File.exists?(Path.join(repo, "ahead-1.txt"))
      assert rev(origin, "refs/heads/main") != local_head
    end

    test "self-host skip matches a symlink to the same tree, not a project name" do
      %{origin: origin, repo: repo} = GitFixture.init_with_origin()
      advance_origin(origin)
      link = repo <> "-alias"
      File.ln_s!(repo, link)
      on_exit(fn -> File.rm_rf(link) end)
      stub_node_source_root(link)
      local_head = rev(repo, "HEAD")

      assert {:skipped, reason} = TargetSync.ff_local(repo, "main")

      assert reason =~ "self-host:"
      assert rev(repo, "HEAD") == local_head
    end
  end

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

  @spec rev(String.t(), String.t()) :: String.t()
  defp rev(repo, ref), do: repo |> GitFixture.git!(["rev-parse", ref]) |> String.trim()

  # Push `count` commits to origin/main from a throwaway clone, leaving `repo`
  # (the operator checkout) behind — the TargetSync happy-path fixture.
  @spec advance_origin(String.t(), pos_integer()) :: :ok
  defp advance_origin(origin, count \\ 1) when count >= 1 do
    clone = Path.join(System.tmp_dir!(), "git-ahead-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(clone) end)

    {_out, 0} = System.cmd("git", ["clone", "-q", origin, clone], stderr_to_stdout: true)
    GitFixture.git!(clone, ["config", "user.email", "ahead@example.com"])
    GitFixture.git!(clone, ["config", "user.name", "Ahead"])

    Enum.each(1..count, fn i ->
      File.write!(Path.join(clone, "ahead-#{i}.txt"), "#{i}\n")
      GitFixture.git!(clone, ["add", "ahead-#{i}.txt"])
      GitFixture.git!(clone, ["commit", "-q", "-m", "ahead #{i}"])
    end)

    GitFixture.git!(clone, ["push", "-q", "origin", "main"])
    :ok
  end

  @spec stub_node_source_root(String.t()) :: :ok
  defp stub_node_source_root(path) do
    previous = Application.get_env(:harness, :node_source_root)
    Application.put_env(:harness, :node_source_root, path)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:harness, :node_source_root)
      else
        Application.put_env(:harness, :node_source_root, previous)
      end
    end)

    :ok
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
