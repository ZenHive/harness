defmodule Harness.ProjectTest do
  use ExUnit.Case, async: true

  alias Harness.GitFixture
  alias Harness.Project

  describe "%Project{}" do
    test "requires name, source, and roadmap_path; everything else defaults" do
      project = %Project{
        name: "demo",
        source: {:local, "/tmp/demo"},
        roadmap_path: "/tmp/demo"
      }

      assert project.name == "demo"
      assert project.check_command == nil
      assert project.concurrency_cap == nil
      assert project.landing_policy == :manual
      assert project.target_branch == nil
      assert project.pollution_allowlist == nil
    end

    test "carries the reviewer's check-command hint as free text" do
      project = %Project{
        name: "demo",
        source: {:local, "/tmp/demo"},
        roadmap_path: "/tmp/demo",
        check_command: "mix precommit"
      }

      assert project.check_command == "mix precommit"
    end

    test "accepts a {:github, url} source" do
      project = %Project{
        name: "demo",
        source: {:github, "https://github.com/example/demo.git"},
        roadmap_path: "/tmp/demo"
      }

      assert project.source == {:github, "https://github.com/example/demo.git"}
    end

    test "repo_path/1 expands a local source path" do
      project = %Project{
        name: "demo",
        source: {:local, "relative/repo"},
        roadmap_path: "relative/repo"
      }

      assert Project.repo_path(project) == Path.expand("relative/repo")
    end

    test "repo_path/2 returns the cache path for a github source" do
      project = %Project{
        name: "demo",
        source: {:github, "https://github.com/example/demo.git"},
        roadmap_path: "/tmp/demo"
      }

      cache_root = GitFixture.tmp_base(name: "cache")
      assert Project.repo_path(project, cache_root: cache_root) == Path.join(cache_root, "demo")
    end

    test "ensure_local_repo/1 is a no-op for local sources" do
      project = %Project{
        name: "demo",
        source: {:local, "/tmp/demo"},
        roadmap_path: "/tmp/demo"
      }

      assert {:ok, "/tmp/demo"} = Project.ensure_local_repo(project)
    end
  end
end
