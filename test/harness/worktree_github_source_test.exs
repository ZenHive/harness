defmodule Harness.WorktreeGithubSourceTest do
  # async: false — GithubFixture.allowlisted_url/1 installs the local-upstream
  # rewrite through the process-global GIT_CONFIG_* env, which cannot be shared
  # with concurrently running suites.
  use ExUnit.Case, async: false

  alias Harness.GitFixture
  alias Harness.GithubFixture
  alias Harness.Project
  alias Harness.Worktree

  describe "create/2 — github source" do
    test "clones the upstream cache on first call, then carves a worktree off it" do
      upstream = GithubFixture.init_upstream(name: "wt-clone")
      project = github_project("wt-clone", upstream)
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
      project = github_project("wt-fetch", upstream)
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
      project = github_project("wt-recover", upstream)
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
      project = build_project("wt-bad", GithubFixture.allowlisted_url(bogus))
      cache_root = GitFixture.tmp_base(name: "cache")
      base = GitFixture.tmp_base()

      assert {:error, {:source_unavailable, {:clone_failed, status, _output}}} =
               Worktree.create(project, base_dir: base, cache_root: cache_root)

      assert status != 0
    end

    test "surfaces a source_unavailable error when the upstream URL is not allowlisted" do
      project = build_project("wt-ext", "ext::sh -c echo exploit %S")
      cache_root = GitFixture.tmp_base(name: "cache")
      base = GitFixture.tmp_base()

      assert {:error, {:source_unavailable, {:invalid_url, :unsupported_scheme}}} =
               Worktree.create(project, base_dir: base, cache_root: cache_root)

      refute File.exists?(cache_root)
    end
  end

  defp github_project(name, upstream), do: build_project(name, GithubFixture.allowlisted_url(upstream.bare_path))

  defp build_project(name, url) do
    %Project{
      name: name,
      source: {:github, url},
      roadmap_path: "/tmp/#{name}",
      languages: [:elixir]
    }
  end
end
