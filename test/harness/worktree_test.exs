defmodule Harness.WorktreeTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Claude
  alias Harness.AgentAdapter.Codex
  alias Harness.AgentAdapter.Cursor
  alias Harness.AgentAdapter.Invocation
  alias Harness.GitFixture
  alias Harness.GithubFixture
  alias Harness.Project
  alias Harness.ProjectFixture
  alias Harness.Worktree

  describe "create/2" do
    test "carves an isolated worktree and branch off HEAD" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()
      project = ProjectFixture.from_repo(repo)

      assert {:ok, %Worktree{} = wt} = Worktree.create(project, base_dir: base)

      assert String.starts_with?(wt.id, "run-")
      assert wt.branch == "harness/" <> wt.id
      assert wt.repo == Path.expand(repo)
      assert wt.path == Path.join([base, project.name, wt.id])
      assert File.dir?(wt.path)
      assert File.exists?(Path.join(wt.path, ".git"))
      assert GitFixture.git!(repo, ["branch", "--list", wt.branch]) =~ wt.branch
      assert GitFixture.git!(repo, ["worktree", "list"]) =~ wt.path
    end

    test "honors the :base_ref option" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()
      GitFixture.git!(repo, ["checkout", "-q", "-b", "feature"])
      GitFixture.git!(repo, ["commit", "--allow-empty", "-q", "-m", "feature work"])
      GitFixture.git!(repo, ["checkout", "-q", "main"])
      feature_sha = String.trim(GitFixture.git!(repo, ["rev-parse", "feature"]))

      assert {:ok, wt} = Worktree.create(ProjectFixture.from_repo(repo), base_dir: base, base_ref: "feature")

      assert String.trim(GitFixture.git!(wt.path, ["rev-parse", "HEAD"])) == feature_sha
      assert wt.base_sha == feature_sha
    end

    test "captures the resolved base SHA on the worktree handle" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()
      head_sha = String.trim(GitFixture.git!(repo, ["rev-parse", "HEAD"]))

      assert {:ok, wt} = Worktree.create(ProjectFixture.from_repo(repo), base_dir: base)

      assert wt.base_sha == head_sha
    end

    test "honors the :id option" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()

      assert {:ok, wt} = Worktree.create(ProjectFixture.from_repo(repo), base_dir: base, id: "run-fixed-id")

      assert wt.id == "run-fixed-id"
      assert wt.branch == "harness/run-fixed-id"
    end

    test "reuses an existing run branch left by a crashed prior attempt" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()
      run_id = "run-retry-branch"
      branch = "harness/#{run_id}"

      GitFixture.git!(repo, ["branch", branch])

      assert {:ok, wt} = Worktree.create(ProjectFixture.from_repo(repo), base_dir: base, id: run_id)

      assert wt.id == run_id
      assert wt.branch == branch
      assert File.dir?(wt.path)
      assert String.trim(GitFixture.git!(wt.path, ["branch", "--show-current"])) == branch
    end

    test "rejects a path that is not a git repository" do
      base = GitFixture.tmp_base()
      plain = GitFixture.tmp_base(name: "plain")
      File.mkdir_p!(plain)

      assert {:error, {:not_a_git_repo, ^plain}} = Worktree.create(ProjectFixture.from_repo(plain), base_dir: base)
    end

    test "rejects a path that does not exist" do
      base = GitFixture.tmp_base()
      missing = Path.join(System.tmp_dir!(), "harness-missing-#{System.unique_integer([:positive])}")

      assert {:error, {:repo_not_found, expanded}} = Worktree.create(ProjectFixture.from_repo(missing), base_dir: base)
      assert expanded == Path.expand(missing)
    end

    test "concurrent creates on one repo never collide" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()

      worktrees =
        1..8
        |> Task.async_stream(fn _ -> Worktree.create(ProjectFixture.from_repo(repo), base_dir: base) end,
          max_concurrency: 8,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, {:ok, wt}} -> wt end)

      assert length(worktrees) == 8
      assert worktrees |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 8
      assert worktrees |> Enum.map(& &1.path) |> Enum.uniq() |> length() == 8
      assert worktrees |> Enum.map(& &1.branch) |> Enum.uniq() |> length() == 8
      assert Enum.all?(worktrees, &File.dir?(&1.path))
    end

    test "retries a transient worktree-create ref lock before failing" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()
      run_id = "run-create-lock"
      lock = git_branch_lock!(repo, "harness/#{run_id}")
      parent = self()

      spawn(fn ->
        Process.sleep(30)
        _ = File.rm(lock)
        send(parent, :lock_cleared)
      end)

      assert {:ok, %Worktree{} = wt} =
               Worktree.create(ProjectFixture.from_repo(repo),
                 base_dir: base,
                 id: run_id,
                 substrate_retry: [max_retries: 5, base_delay_ms: 10, max_delay_ms: 10]
               )

      assert_receive :lock_cleared
      assert wt.branch == "harness/#{run_id}"
      assert File.dir?(wt.path)
    end

    test "propagates the .sobelow-skips baseline from the parent repo into the worktree" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()
      File.write!(Path.join(repo, ".sobelow-skips"), "Traversal.FileModule: fake,foo.ex:1,DEADBEEF\n")

      assert {:ok, wt} = Worktree.create(ProjectFixture.from_repo(repo), base_dir: base)

      assert File.read!(Path.join(wt.path, ".sobelow-skips")) =~ "DEADBEEF"
    end

    test "silently skips propagation when the parent repo has no .sobelow-skips" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()

      assert {:ok, wt} = Worktree.create(ProjectFixture.from_repo(repo), base_dir: base)

      refute File.exists?(Path.join(wt.path, ".sobelow-skips"))
    end
  end

  describe "warm/2" do
    test "seeds configured gitignored build dirs from the parent into the worktree" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()
      File.mkdir_p!(Path.join(repo, "deps/foo"))
      File.write!(Path.join(repo, "deps/foo/mix.exs"), "compiled-dep")
      File.mkdir_p!(Path.join(repo, "priv/plts"))
      File.write!(Path.join(repo, "priv/plts/core.plt"), "PLT")

      assert {:ok, wt} = Worktree.create(ProjectFixture.from_repo(repo), base_dir: base)
      # git worktree add only materializes tracked files — the untracked build
      # dirs are absent until warming copies them in.
      refute File.exists?(Path.join(wt.path, "deps/foo/mix.exs"))

      assert :ok = Worktree.warm(wt, warm_paths: ["deps", "priv/plts"])

      assert File.read!(Path.join(wt.path, "deps/foo/mix.exs")) == "compiled-dep"
      assert File.read!(Path.join(wt.path, "priv/plts/core.plt")) == "PLT"
    end

    test "extends default warm dirs with project warm paths" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()
      project = ProjectFixture.from_repo(repo, warm_paths: ["priv/foo"])

      File.mkdir_p!(Path.join(repo, "deps/foo"))
      File.write!(Path.join(repo, "deps/foo/mix.exs"), "compiled-dep")
      File.mkdir_p!(Path.join(repo, "_build/test"))
      File.write!(Path.join(repo, "_build/test/app.beam"), "compiled-app")
      File.mkdir_p!(Path.join(repo, "priv/foo"))
      File.write!(Path.join(repo, "priv/foo/corpus.json"), "{}")

      assert {:ok, wt} = Worktree.create(project, base_dir: base)

      assert :ok = Worktree.warm(wt, warm_paths: project.warm_paths)

      assert File.read!(Path.join(wt.path, "deps/foo/mix.exs")) == "compiled-dep"
      assert File.read!(Path.join(wt.path, "_build/test/app.beam")) == "compiled-app"
      assert File.read!(Path.join(wt.path, "priv/foo/corpus.json")) == "{}"
    end

    test "uses the same default warm dirs when a project leaves warm paths unset" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()

      File.mkdir_p!(Path.join(repo, "deps/foo"))
      File.write!(Path.join(repo, "deps/foo/mix.exs"), "compiled-dep")
      File.mkdir_p!(Path.join(repo, "_build/test"))
      File.write!(Path.join(repo, "_build/test/app.beam"), "compiled-app")
      File.mkdir_p!(Path.join(repo, "priv/plts"))
      File.write!(Path.join(repo, "priv/plts/core.plt"), "PLT")

      assert {:ok, wt} = Worktree.create(ProjectFixture.from_repo(repo), base_dir: base)

      assert :ok = Worktree.warm(wt)

      assert File.read!(Path.join(wt.path, "deps/foo/mix.exs")) == "compiled-dep"
      assert File.read!(Path.join(wt.path, "_build/test/app.beam")) == "compiled-app"
      assert File.read!(Path.join(wt.path, "priv/plts/core.plt")) == "PLT"
    end

    test "never clobbers a path the worktree already produced" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()
      File.mkdir_p!(Path.join(repo, "deps"))
      File.write!(Path.join(repo, "deps/parent.txt"), "parent")

      assert {:ok, wt} = Worktree.create(ProjectFixture.from_repo(repo), base_dir: base)
      File.mkdir_p!(Path.join(wt.path, "deps"))
      File.write!(Path.join(wt.path, "deps/agent.txt"), "agent")

      assert :ok = Worktree.warm(wt, warm_paths: ["deps"])

      # The worktree already had deps/ — warm leaves it untouched, never merging
      # the parent's copy over agent-produced state.
      assert File.read!(Path.join(wt.path, "deps/agent.txt")) == "agent"
      refute File.exists?(Path.join(wt.path, "deps/parent.txt"))
    end

    test "is a best-effort no-op for a configured path the parent lacks" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()

      assert {:ok, wt} = Worktree.create(ProjectFixture.from_repo(repo), base_dir: base)

      assert :ok = Worktree.warm(wt, warm_paths: ["_build", "deps"])
      refute File.exists?(Path.join(wt.path, "_build"))
      refute File.exists?(Path.join(wt.path, "deps"))
    end
  end

  describe "create/2 — push neuter (Task 186)" do
    test "neuters push in the run worktree without leaking to the main checkout" do
      %{origin: origin, repo: repo} = GitFixture.init_with_origin()
      base = GitFixture.tmp_base()

      assert {:ok, wt} = Worktree.create(ProjectFixture.from_repo(repo), base_dir: base)

      # Push from the run worktree fails locally (no network): pushurl is the
      # /dev/null sentinel, so git never reaches origin and nothing lands there.
      {_output, status} = System.cmd("git", ["push", "origin", "HEAD"], cd: wt.path, stderr_to_stdout: true)
      assert status != 0
      refute GitFixture.git!(origin, ["branch", "--list", wt.branch]) =~ wt.branch

      # The override is scoped to the run worktree's config.worktree, not the
      # shared config the main checkout / lander read.
      assert String.trim(GitFixture.git!(wt.path, ["config", "--get", "remote.origin.pushurl"])) == "/dev/null"
      assert {_o, 1} = System.cmd("git", ["-C", repo, "config", "--get", "remote.origin.pushurl"], stderr_to_stdout: true)

      # Fetch still works in the run worktree — only push is neutered.
      GitFixture.git!(wt.path, ["fetch", "-q", "origin"])

      # The main checkout can still push: the operator/lander path is unaffected.
      GitFixture.git!(repo, ["checkout", "-q", "-b", "main-extra"])
      GitFixture.git!(repo, ["commit", "--allow-empty", "-q", "-m", "post-neuter push"])
      GitFixture.git!(repo, ["push", "-q", "origin", "main-extra"])
    end
  end

  describe "create/2 — github source" do
    test "clones the upstream cache on first call, then carves a worktree off it" do
      upstream = GithubFixture.init_upstream(name: "wt-clone")
      project = github_project("wt-clone", upstream.bare_path)
      cache_root = GitFixture.tmp_base(name: "cache")
      base = GitFixture.tmp_base()

      refute File.dir?(Path.join(cache_root, project.name))

      assert {:ok, wt} =
               Worktree.create(project, base_dir: base, cache_root: cache_root)

      cache_path = Path.join(cache_root, project.name)
      assert wt.repo == cache_path
      assert File.dir?(Path.join(cache_path, ".git"))
      assert wt.path == Path.join([base, project.name, wt.id])
      assert File.exists?(Path.join(wt.path, "README.md"))
    end

    test "fetches before carving the worktree on subsequent calls" do
      upstream = GithubFixture.init_upstream(name: "wt-fetch")
      project = github_project("wt-fetch", upstream.bare_path)
      cache_root = GitFixture.tmp_base(name: "cache")
      base = GitFixture.tmp_base()

      {:ok, _first} = Worktree.create(project, base_dir: base, cache_root: cache_root)

      GithubFixture.push_commit(upstream, file: "fresh.txt", content: "after fetch\n")

      assert {:ok, wt} =
               Worktree.create(project, base_dir: base, cache_root: cache_root)

      assert File.read!(Path.join(wt.path, "fresh.txt")) == "after fetch\n"
    end

    test "transparently re-clones after the cache directory is removed" do
      upstream = GithubFixture.init_upstream(name: "wt-recover")
      project = github_project("wt-recover", upstream.bare_path)
      cache_root = GitFixture.tmp_base(name: "cache")
      base = GitFixture.tmp_base()

      {:ok, _first} = Worktree.create(project, base_dir: base, cache_root: cache_root)
      File.rm_rf!(Path.join(cache_root, project.name))

      assert {:ok, wt} =
               Worktree.create(project, base_dir: base, cache_root: cache_root)

      assert File.dir?(wt.path)
      assert File.exists?(Path.join(wt.path, "README.md"))
    end

    test "surfaces a source_unavailable error when the upstream URL is unreachable" do
      bogus = Path.join(System.tmp_dir!(), "harness-not-a-repo-#{System.unique_integer([:positive])}")
      project = github_project("wt-bad", bogus)
      cache_root = GitFixture.tmp_base(name: "cache")
      base = GitFixture.tmp_base()

      assert {:error, {:source_unavailable, {:clone_failed, status, _output}}} =
               Worktree.create(project, base_dir: base, cache_root: cache_root)

      assert status != 0
    end
  end

  describe "commit/2" do
    test "commits the worktree's changes onto its branch" do
      {repo, wt} = create_worktree()
      File.write!(Path.join(wt.path, "delivery.txt"), "agent work\n")

      assert {:ok, :committed} = Worktree.commit(wt, "agent delivery")

      assert GitFixture.git!(repo, ["show", "#{wt.branch}:delivery.txt"]) == "agent work\n"
      assert GitFixture.git!(repo, ["log", "-1", "--format=%s", wt.branch]) =~ "agent delivery"
    end

    test "stamps an explicit harness committer identity" do
      {repo, wt} = create_worktree()
      File.write!(Path.join(wt.path, "delivery.txt"), "agent work\n")

      assert {:ok, :committed} = Worktree.commit(wt, "agent delivery")

      assert GitFixture.git!(repo, ["log", "-1", "--format=%an <%ae>", wt.branch]) =~
               "harness <harness@localhost>"
    end

    test "reports :no_changes and commits nothing on a clean worktree" do
      {repo, wt} = create_worktree()
      sha_before = GitFixture.git!(repo, ["rev-parse", wt.branch])

      assert {:ok, :no_changes} = Worktree.commit(wt, "agent delivery")

      assert GitFixture.git!(repo, ["rev-parse", wt.branch]) == sha_before
    end

    test "reports :no_changes after Claude injects rules into a no-op run" do
      {repo, wt} = create_worktree()
      sha_before = GitFixture.git!(repo, ["rev-parse", wt.branch])

      assert {:ok, {"claude", _argv, _env}} = Claude.build_command(invocation(wt.path))
      assert {:ok, :no_changes} = Worktree.commit(wt, "agent delivery")

      assert GitFixture.git!(repo, ["rev-parse", wt.branch]) == sha_before
    end

    test "reports :no_changes after Codex injects rules into a no-op run" do
      {repo, wt} = create_worktree()
      sha_before = GitFixture.git!(repo, ["rev-parse", wt.branch])

      assert {:ok, {"codex", _argv, _env}} = Codex.build_command(invocation(wt.path))
      assert {:ok, :no_changes} = Worktree.commit(wt, "agent delivery")

      assert GitFixture.git!(repo, ["rev-parse", wt.branch]) == sha_before
    end

    test "reports :no_changes after Cursor injects rules into a no-op run" do
      {repo, wt} = create_worktree()
      sha_before = GitFixture.git!(repo, ["rev-parse", wt.branch])

      assert {:ok, {"cursor-agent", _argv, _env}} = Cursor.build_command(invocation(wt.path))
      assert {:ok, :no_changes} = Worktree.commit(wt, "agent delivery")

      assert GitFixture.git!(repo, ["rev-parse", wt.branch]) == sha_before
    end

    test "does not commit Codex's harness block into an existing AGENTS.md" do
      repo = GitFixture.init_repo()
      File.write!(Path.join(repo, "AGENTS.md"), "target repo instructions\n")
      GitFixture.git!(repo, ["add", "AGENTS.md"])
      GitFixture.git!(repo, ["commit", "-q", "-m", "add agents"])
      base = GitFixture.tmp_base()
      {:ok, wt} = Worktree.create(ProjectFixture.from_repo(repo), base_dir: base)
      sha_before = GitFixture.git!(repo, ["rev-parse", wt.branch])

      assert {:ok, {"codex", _argv, _env}} = Codex.build_command(invocation(wt.path))
      assert {:ok, :no_changes} = Worktree.commit(wt, "agent delivery")

      assert GitFixture.git!(repo, ["rev-parse", wt.branch]) == sha_before
      assert File.read!(Path.join(wt.path, "AGENTS.md")) == "target repo instructions\n"
    end

    test "commits legitimate Codex edits to AGENTS.md without the harness block" do
      {repo, wt} = create_worktree()

      assert {:ok, {"codex", _argv, _env}} = Codex.build_command(invocation(wt.path))
      agents = Path.join(wt.path, "AGENTS.md")
      File.write!(agents, File.read!(agents) <> "\nproject rules\n")

      assert {:ok, :committed} = Worktree.commit(wt, "agent delivery")

      assert GitFixture.git!(repo, ["show", "#{wt.branch}:AGENTS.md"]) == "project rules\n"
    end

    test "surfaces a git failure on a path that is not a git repository" do
      plain = GitFixture.tmp_base(name: "plain")
      File.mkdir_p!(plain)

      bogus = %Worktree{
        id: "run-x",
        path: plain,
        branch: "harness/run-x",
        repo: plain,
        base_sha: "0000000000000000000000000000000000000000"
      }

      assert {:error, {:git_failed, _args, status, _output}} = Worktree.commit(bogus, "agent delivery")
      assert status != 0
    end

    test "retries a transient git lock that clears before failing the commit" do
      {_repo, wt} = create_worktree()
      File.write!(Path.join(wt.path, "delivery.txt"), "agent work\n")
      lock = git_index_lock!(wt.path)
      parent = self()

      spawn(fn ->
        Process.sleep(30)
        _ = File.rm(lock)
        send(parent, :lock_cleared)
      end)

      assert {:ok, :committed} =
               Worktree.commit(wt, "agent delivery",
                 substrate_retry: [max_retries: 5, base_delay_ms: 10, max_delay_ms: 10]
               )

      assert_receive :lock_cleared
    end

    test "persistent git failures still fail after the bounded retry count" do
      {_repo, wt} = create_worktree()
      File.write!(Path.join(wt.path, "delivery.txt"), "agent work\n")
      _lock = git_index_lock!(wt.path)

      assert {:error, {:git_failed, _args, status, _output}} =
               Worktree.commit(wt, "agent delivery", substrate_retry: [max_retries: 2, base_delay_ms: 1, max_delay_ms: 1])

      assert status != 0
    end

    test "mechanical retry does not add git error-string classifiers" do
      source = File.read!("lib/harness/worktree.ex") <> File.read!("lib/harness/run.ex")

      refute source =~ "index.lock"
      refute source =~ "another git process"
      refute source =~ "Unable to create"
    end

    test "re-attaches and commits when the agent detached HEAD at the branch tip" do
      {repo, wt} = create_worktree()
      File.write!(Path.join(wt.path, "delivery.txt"), "agent work\n")
      GitFixture.git!(wt.path, ["checkout", "-q", "--detach"])

      assert {:ok, :committed} = Worktree.commit(wt, "agent delivery")

      # HEAD is back on the run branch and the deliverable landed on it.
      assert String.trim(GitFixture.git!(wt.path, ["branch", "--show-current"])) == wt.branch
      assert GitFixture.git!(repo, ["show", "#{wt.branch}:delivery.txt"]) == "agent work\n"
    end

    test "re-attaches and commits when the agent switched HEAD to a different branch" do
      {repo, wt} = create_worktree()
      File.write!(Path.join(wt.path, "delivery.txt"), "agent work\n")
      GitFixture.git!(wt.path, ["checkout", "-q", "-b", "agent-detour"])

      assert {:ok, :committed} = Worktree.commit(wt, "agent delivery")

      assert String.trim(GitFixture.git!(wt.path, ["branch", "--show-current"])) == wt.branch
      assert GitFixture.git!(repo, ["show", "#{wt.branch}:delivery.txt"]) == "agent work\n"
    end

    test "fast-forwards the branch when the agent committed while detached (HEAD ahead)" do
      {repo, wt} = create_worktree()
      # Agent detaches, commits its delivery off-branch, then leaves HEAD there.
      GitFixture.git!(wt.path, ["checkout", "-q", "--detach"])
      File.write!(Path.join(wt.path, "delivery.txt"), "agent work\n")
      GitFixture.git!(wt.path, ["add", "delivery.txt"])
      GitFixture.git!(wt.path, ["commit", "-q", "-m", "off-branch delivery"])
      detached_sha = String.trim(GitFixture.git!(wt.path, ["rev-parse", "HEAD"]))

      assert {:ok, :no_changes} = Worktree.commit(wt, "agent delivery")

      # The branch was fast-forwarded onto the detached commit — work preserved.
      assert String.trim(GitFixture.git!(wt.path, ["branch", "--show-current"])) == wt.branch
      assert String.trim(GitFixture.git!(repo, ["rev-parse", wt.branch])) == detached_sha
      assert GitFixture.git!(repo, ["show", "#{wt.branch}:delivery.txt"]) == "agent work\n"
    end

    test "re-attaches to the tip when the agent checked out an older commit (HEAD behind)" do
      {repo, wt} = create_worktree()
      File.write!(Path.join(wt.path, "first.txt"), "first\n")
      assert {:ok, :committed} = Worktree.commit(wt, "first delivery")
      tip = String.trim(GitFixture.git!(repo, ["rev-parse", wt.branch]))
      # Agent rewinds HEAD to the base commit, behind the branch tip.
      GitFixture.git!(wt.path, ["checkout", "-q", wt.base_sha])

      assert {:ok, :no_changes} = Worktree.commit(wt, "agent delivery")

      # Re-attached to the tip; the branch keeps the committed deliverable.
      assert String.trim(GitFixture.git!(wt.path, ["branch", "--show-current"])) == wt.branch
      assert String.trim(GitFixture.git!(repo, ["rev-parse", wt.branch])) == tip
    end
  end

  describe "commit/2 — harness artifact staging (Task 282)" do
    test "commits the source change when an untracked, gitignored .harness/ is present" do
      # State A: the target repo gitignores `.harness/` (harness's own shape). The
      # reviewer's verdict artifact under it must not fatal `git add` (the
      # review_stuck bug that bounced task 281) — the source change still commits.
      {repo, wt} = create_worktree_gitignoring_harness()
      File.write!(Path.join(wt.path, "delivery.txt"), "agent work\n")
      write_review_artifact(wt)

      assert {:ok, :committed} = Worktree.commit(wt, "agent delivery")

      files = GitFixture.git!(repo, ["ls-tree", "-r", "--name-only", wt.branch])
      assert files =~ "delivery.txt"
      refute files =~ ".harness"
    end

    test "excludes an untracked .harness/ dir even when the repo does not gitignore it" do
      # State B: no gitignore for `.harness/`. `git add -A` would stage the verdict
      # artifact; the reset step must keep it out of the commit anyway.
      {repo, wt} = create_worktree()
      File.write!(Path.join(wt.path, "delivery.txt"), "agent work\n")
      write_review_artifact(wt)

      assert {:ok, :committed} = Worktree.commit(wt, "agent delivery")

      files = GitFixture.git!(repo, ["ls-tree", "-r", "--name-only", wt.branch])
      assert files =~ "delivery.txt"
      refute files =~ ".harness"
    end

    test "never commits the .harness-retained marker (not gitignored, not under .harness/)" do
      {repo, wt} = create_worktree()
      File.write!(Path.join(wt.path, "delivery.txt"), "agent work\n")
      File.write!(Path.join(wt.path, ".harness-retained"), "branch=#{wt.branch}\n")

      assert {:ok, :committed} = Worktree.commit(wt, "agent delivery")

      files = GitFixture.git!(repo, ["ls-tree", "-r", "--name-only", wt.branch])
      assert files =~ "delivery.txt"
      refute files =~ ".harness-retained"
    end

    test "excludes reviewer-edited roadmap and changelog files from the delivery commit" do
      {repo, wt} = create_worktree()
      File.write!(Path.join(wt.path, "delivery.txt"), "agent work\n")
      File.mkdir_p!(Path.join(wt.path, "roadmap"))
      File.write!(Path.join(wt.path, "roadmap/tasks.toml"), "[[task]]\nid = 999\n")
      File.write!(Path.join(wt.path, "roadmap/data.json"), "{}\n")
      File.write!(Path.join(wt.path, "ROADMAP.md"), "stale render\n")
      File.write!(Path.join(wt.path, "CHANGELOG.md"), "stale history\n")

      assert {:ok, :committed} = Worktree.commit(wt, "agent delivery")

      files = GitFixture.git!(repo, ["ls-tree", "-r", "--name-only", wt.branch])
      assert files =~ "delivery.txt"
      refute files =~ "roadmap/tasks.toml"
      refute files =~ "roadmap/data.json"
      refute files =~ "ROADMAP.md"
      refute files =~ "CHANGELOG.md"
    end

    # The production shape: the target repo already tracks these files, so the
    # exclusion has to drop a *modification* rather than skip an untracked add.
    # A `refute ls-tree` assertion cannot see that difference — the path is in the
    # tree either way — so this asserts the committed content is still the base.
    test "drops modifications to already-tracked roadmap and changelog files" do
      {repo, wt} = create_worktree()
      GitFixture.git!(repo, ["config", "user.email", "fixture@example.com"])
      GitFixture.git!(repo, ["config", "user.name", "fixture"])

      File.mkdir_p!(Path.join(wt.path, "roadmap"))
      File.write!(Path.join(wt.path, "roadmap/tasks.toml"), "[[task]]\nid = 1\n")
      File.write!(Path.join(wt.path, "ROADMAP.md"), "base render\n")
      File.write!(Path.join(wt.path, "CHANGELOG.md"), "base history\n")
      GitFixture.git!(wt.path, ["add", "roadmap/tasks.toml", "ROADMAP.md", "CHANGELOG.md"])
      GitFixture.git!(wt.path, ["commit", "-q", "-m", "base roadmap"])

      File.write!(Path.join(wt.path, "delivery.txt"), "agent work\n")
      File.write!(Path.join(wt.path, "roadmap/tasks.toml"), "[[task]]\nid = 999\n")
      File.write!(Path.join(wt.path, "ROADMAP.md"), "stale render\n")
      File.write!(Path.join(wt.path, "CHANGELOG.md"), "stale history\n")

      assert {:ok, :committed} = Worktree.commit(wt, "agent delivery")

      changed = GitFixture.git!(wt.path, ["diff", "--name-only", "HEAD~1", "HEAD"])
      assert changed =~ "delivery.txt"
      refute changed =~ "roadmap/tasks.toml"
      refute changed =~ "ROADMAP.md"
      refute changed =~ "CHANGELOG.md"

      assert GitFixture.git!(wt.path, ["show", "HEAD:ROADMAP.md"]) =~ "base render"
      assert GitFixture.git!(wt.path, ["show", "HEAD:roadmap/tasks.toml"]) =~ "id = 1"
    end

    test "diff_size measures only the source change, excluding the artifact family" do
      # Source change is exactly 2 added lines; the artifacts add 1 line each. A
      # leak would report 4 — asserting 2 proves the whole `.harness*` family is
      # excluded, in the gitignored state, without fataling.
      {_repo, wt} = create_worktree_gitignoring_harness()
      File.write!(Path.join(wt.path, "delivery.txt"), "line one\nline two\n")
      write_review_artifact(wt)
      File.write!(Path.join(wt.path, ".harness-retained"), "branch=#{wt.branch}\n")

      assert {:ok, 2} = Worktree.diff_size(wt)
    end
  end

  describe "finish/3" do
    test "tears the worktree down on :success, keeping the branch" do
      {repo, wt} = create_worktree()

      assert :ok = Worktree.finish(wt, :success)

      refute File.dir?(wt.path)
      refute GitFixture.git!(repo, ["worktree", "list"]) =~ wt.path
      assert GitFixture.git!(repo, ["branch", "--list", wt.branch]) =~ wt.branch
    end

    test "retains the worktree on :failure by default, dropping a marker" do
      {_repo, wt} = create_worktree()

      assert :ok = Worktree.finish(wt, :failure)

      assert File.dir?(wt.path)
      assert Worktree.retained?(wt.path)
      assert File.read!(Path.join(wt.path, ".harness-retained")) =~ "branch=#{wt.branch}"
    end

    test "tears down on :failure when retain_on_failure is false" do
      {_repo, wt} = create_worktree()

      assert :ok = Worktree.finish(wt, :failure, retain_on_failure: false)

      refute File.dir?(wt.path)
    end

    test "surfaces a marker write failure when the worktree path is gone" do
      {_repo, wt} = create_worktree()
      :ok = Worktree.remove(wt)

      assert {:error, {:marker_write_failed, marker, :enoent}} =
               Worktree.finish(wt, :failure)

      assert marker == Path.join(wt.path, ".harness-retained")
    end
  end

  describe "remove/1" do
    test "removes the worktree directory" do
      {_repo, wt} = create_worktree()

      assert :ok = Worktree.remove(wt)
      refute File.dir?(wt.path)
    end

    test "a second remove surfaces the git failure rather than swallowing it" do
      {_repo, wt} = create_worktree()
      assert :ok = Worktree.remove(wt)

      assert {:error, {:git_failed, _args, status, _output}} = Worktree.remove(wt)
      assert status != 0
    end
  end

  describe "cleanup_for_run/2" do
    test "removes the worktree directory and branch a non-live run left behind" do
      {repo, wt} = create_worktree()

      assert :ok = Worktree.cleanup_for_run(repo, wt.id)

      refute File.dir?(wt.path)
      assert GitFixture.git!(repo, ["branch", "--list", wt.branch]) == ""
    end

    test "refuses to touch a live run's worktree and branch" do
      {repo, wt} = create_worktree()

      # A live gen_statem registers under Harness.Run.Registry keyed by run id.
      # cleanup_for_run must read that as "owned by a live process" and refuse —
      # the 2026-06-03 job-118 case, where a retry's cleanup destroyed the live
      # run's checkout mid-review (→ {:worktree_missing} at :reviewing).
      parent = self()

      live =
        spawn(fn ->
          {:ok, _} = Registry.register(Harness.Run.Registry, wt.id, nil)
          send(parent, :registered)
          Process.sleep(:infinity)
        end)

      assert_receive :registered
      on_exit(fn -> Process.exit(live, :kill) end)

      assert {:error, :live_run} = Worktree.cleanup_for_run(repo, wt.id)

      assert File.dir?(wt.path)
      assert GitFixture.git!(repo, ["branch", "--list", wt.branch]) =~ wt.branch
    end
  end

  describe "retained?/1" do
    test "is false for a fresh worktree, true once retained" do
      {_repo, wt} = create_worktree()
      refute Worktree.retained?(wt.path)

      assert :ok = Worktree.finish(wt, :failure)
      assert Worktree.retained?(wt.path)
    end
  end

  describe "base_dir/1" do
    test "the :base_dir option overrides the configured fallback" do
      assert Worktree.base_dir(base_dir: "/tmp/explicit") == "/tmp/explicit"
    end

    test "falls back to configuration when no option is given" do
      assert Worktree.base_dir() == Application.get_env(:harness, :worktree)[:base_dir]
    end
  end

  defp create_worktree do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    {:ok, wt} = Worktree.create(ProjectFixture.from_repo(repo), base_dir: base)
    {repo, wt}
  end

  # A worktree off a parent that gitignores `.harness/` — harness's own repo
  # shape, where an untracked verdict artifact under the dir used to fatal staging.
  @spec create_worktree_gitignoring_harness() :: {String.t(), Worktree.t()}
  defp create_worktree_gitignoring_harness do
    repo = GitFixture.init_repo()
    File.write!(Path.join(repo, ".gitignore"), ".harness/\n")
    GitFixture.git!(repo, ["add", ".gitignore"])
    GitFixture.git!(repo, ["commit", "-q", "-m", "gitignore harness artifacts"])
    base = GitFixture.tmp_base()
    {:ok, wt} = Worktree.create(ProjectFixture.from_repo(repo), base_dir: base)
    {repo, wt}
  end

  # The reviewer's verdict artifact, under the run-local `.harness/` dir.
  @spec write_review_artifact(Worktree.t()) :: :ok
  defp write_review_artifact(%Worktree{path: path}) do
    File.mkdir_p!(Path.join(path, ".harness"))
    File.write!(Path.join([path, ".harness", "review.json"]), ~s({"verdict":"approve"}\n))
  end

  defp invocation(cwd) do
    %Invocation{prompt: "do nothing", cwd: cwd, log_tag: "36"}
  end

  defp git_index_lock!(path) do
    git_dir = git_dir(path)
    lock = Path.join(git_dir, "index.lock")
    File.write!(lock, "locked\n")
    lock
  end

  defp git_branch_lock!(repo, branch) do
    git_dir = git_dir(repo)
    lock = Path.join([git_dir, "refs", "heads", branch <> ".lock"])
    File.mkdir_p!(Path.dirname(lock))
    File.write!(lock, "locked\n")
    lock
  end

  defp git_dir(path) do
    git_dir = String.trim(GitFixture.git!(path, ["rev-parse", "--git-dir"]))
    if Path.type(git_dir) == :absolute, do: git_dir, else: Path.expand(git_dir, path)
  end

  defp github_project(name, url) do
    %Project{
      name: name,
      source: {:github, url},
      roadmap_path: "/tmp/#{name}",
      languages: [:elixir]
    }
  end
end
