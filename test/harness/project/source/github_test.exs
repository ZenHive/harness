defmodule Harness.Project.Source.GithubTest do
  use ExUnit.Case, async: true

  alias Harness.GitFixture
  alias Harness.GithubFixture
  alias Harness.Project
  alias Harness.Project.Source.Github

  describe "url/1" do
    test "returns the URL from a github-source project" do
      project = build_project("demo", "https://github.com/octocat/Hello-World.git")
      assert Github.url(project) == "https://github.com/octocat/Hello-World.git"
    end
  end

  describe "local_path/2" do
    test "joins the cache root with the project's name" do
      project = build_project("demo", "https://example.invalid/r.git")
      cache_root = GitFixture.tmp_base(name: "cache")

      assert Github.local_path(project, cache_root: cache_root) ==
               Path.join(cache_root, "demo")
    end

    test "expands the configured cache root with a leading ~" do
      project = build_project("demo", "https://example.invalid/r.git")

      assert Github.local_path(project, cache_root: "~/_DATA/harness/projects") ==
               Path.join(Path.expand("~/_DATA/harness/projects"), "demo")
    end

    test "does not touch the filesystem" do
      project = build_project("ghost", "https://example.invalid/r.git")
      cache_root = GitFixture.tmp_base(name: "cache")

      path = Github.local_path(project, cache_root: cache_root)

      refute File.exists?(path)
    end
  end

  describe "ensure_local/2 — first clone" do
    test "clones the upstream into <cache_root>/<name> when the cache is empty" do
      upstream = GithubFixture.init_upstream(name: "ensure-clone")
      project = build_project("ensure-clone", upstream.bare_path)
      cache_root = GitFixture.tmp_base(name: "cache")

      assert {:ok, path} = Github.ensure_local(project, cache_root: cache_root)

      assert path == Path.join(cache_root, "ensure-clone")
      assert File.dir?(Path.join(path, ".git"))
      assert File.read!(Path.join(path, "README.md")) == "harness git fixture\n"
    end

    test "creates the cache_root parent directory if missing" do
      upstream = GithubFixture.init_upstream(name: "mkdir-parent")
      project = build_project("mkdir-parent", upstream.bare_path)
      tmp = GitFixture.tmp_base(name: "missing-cache")
      nested_cache = Path.join([tmp, "nested", "cache"])

      assert {:ok, path} = Github.ensure_local(project, cache_root: nested_cache)

      assert File.dir?(path)
    end

    test "surfaces a clone failure when the URL is unreachable" do
      bogus = Path.join(System.tmp_dir!(), "harness-not-a-repo-#{System.unique_integer([:positive])}")
      project = build_project("bogus", bogus)
      cache_root = GitFixture.tmp_base(name: "cache")

      assert {:error, {:clone_failed, status, output}} =
               Github.ensure_local(project, cache_root: cache_root)

      assert status != 0
      assert is_binary(output)
    end
  end

  describe "ensure_local/2 — subsequent fetch" do
    test "fast-forwards the local default branch to upstream after fetch" do
      upstream = GithubFixture.init_upstream(name: "fetch-ff")
      project = build_project("fetch-ff", upstream.bare_path)
      cache_root = GitFixture.tmp_base(name: "cache")

      {:ok, path} = Github.ensure_local(project, cache_root: cache_root)
      initial_sha = String.trim(GitFixture.git!(path, ["rev-parse", "HEAD"]))

      GithubFixture.push_commit(upstream, file: "new.txt", content: "added later\n")
      upstream_sha = String.trim(GitFixture.git!(upstream.bare_path, ["rev-parse", "main"]))

      assert {:ok, ^path} = Github.ensure_local(project, cache_root: cache_root)

      new_sha = String.trim(GitFixture.git!(path, ["rev-parse", "refs/heads/main"]))
      assert new_sha != initial_sha
      assert new_sha == upstream_sha
    end

    test "is a no-op against an upstream that has not advanced" do
      upstream = GithubFixture.init_upstream(name: "fetch-noop")
      project = build_project("fetch-noop", upstream.bare_path)
      cache_root = GitFixture.tmp_base(name: "cache")

      {:ok, path} = Github.ensure_local(project, cache_root: cache_root)
      sha_before = String.trim(GitFixture.git!(path, ["rev-parse", "refs/heads/main"]))

      assert {:ok, ^path} = Github.ensure_local(project, cache_root: cache_root)
      sha_after = String.trim(GitFixture.git!(path, ["rev-parse", "refs/heads/main"]))

      assert sha_after == sha_before
    end
  end

  describe "ensure_local/2 — cache recovery" do
    test "transparently re-clones when the cache directory was removed" do
      upstream = GithubFixture.init_upstream(name: "recovery")
      project = build_project("recovery", upstream.bare_path)
      cache_root = GitFixture.tmp_base(name: "cache")

      {:ok, path} = Github.ensure_local(project, cache_root: cache_root)
      assert File.dir?(path)
      File.rm_rf!(path)
      refute File.dir?(path)

      assert {:ok, ^path} = Github.ensure_local(project, cache_root: cache_root)

      assert File.dir?(Path.join(path, ".git"))
      assert File.read!(Path.join(path, "README.md")) == "harness git fixture\n"
    end
  end

  defp build_project(name, url) do
    %Project{
      name: name,
      source: {:github, url},
      roadmap_path: "/tmp/#{name}",
      languages: [:elixir]
    }
  end
end
