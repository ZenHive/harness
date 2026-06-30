defmodule Harness.Project.Source.GithubIntegrationTest do
  # Integration: exercises a real public GitHub URL (octocat/Hello-World, a
  # tiny demo repo GitHub owns and treats as stable). Excluded by default
  # because it requires outbound network — run with `mix test --include
  # integration`.

  use ExUnit.Case, async: true

  alias Harness.GitFixture
  alias Harness.Project
  alias Harness.Project.Source.Github
  alias Harness.Worktree

  @moduletag :integration

  @public_url "https://github.com/octocat/Hello-World.git"

  describe "ensure_local/2 against a real public GitHub URL" do
    @tag timeout: 60_000
    test "clones, fetches, and re-clones after cache removal" do
      project = github_project("hello-world")
      cache_root = GitFixture.tmp_base(name: "github-int-cache")

      # First call: clone.
      assert {:ok, path} = Github.ensure_local(project, cache_root: cache_root)
      assert File.dir?(Path.join(path, ".git"))
      first_sha = String.trim(GitFixture.git!(path, ["rev-parse", "HEAD"]))
      assert first_sha != ""

      # Second call: fetch. SHA should not move (octocat/Hello-World is stable)
      # but the fetch itself must succeed and the call must return :ok.
      assert {:ok, ^path} = Github.ensure_local(project, cache_root: cache_root)
      second_sha = String.trim(GitFixture.git!(path, ["rev-parse", "HEAD"]))
      assert second_sha == first_sha

      # Recovery: delete the cache and call again — should re-clone, not error.
      File.rm_rf!(path)
      refute File.dir?(path)

      assert {:ok, ^path} = Github.ensure_local(project, cache_root: cache_root)
      assert File.dir?(Path.join(path, ".git"))
    end
  end

  describe "Worktree.create/2 against a GitHub-source project" do
    @tag timeout: 60_000
    test "carves a worktree end-to-end from a real public URL" do
      project = github_project("hello-world-wt")
      cache_root = GitFixture.tmp_base(name: "github-int-cache")
      base = GitFixture.tmp_base(name: "github-int-base")

      assert {:ok, wt} =
               Worktree.create(project, base_dir: base, cache_root: cache_root)

      assert String.starts_with?(wt.id, "run-")
      assert wt.branch == "harness/" <> wt.id
      assert wt.repo == Path.join(cache_root, project.name)
      assert wt.path == Path.join([base, project.name, wt.id])
      assert File.dir?(wt.path)
      assert File.exists?(Path.join(wt.path, ".git"))
      # Hello-World ships a README — confirm the worktree was actually carved
      # from the cloned upstream, not an empty branch.
      assert File.exists?(Path.join(wt.path, "README"))
    end
  end

  defp github_project(name) do
    %Project{
      name: name,
      source: {:github, @public_url},
      roadmap_path: "/tmp/#{name}",
      languages: [:elixir]
    }
  end
end
