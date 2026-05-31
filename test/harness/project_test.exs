defmodule Harness.ProjectTest do
  use ExUnit.Case, async: true

  alias Harness.CheckStack
  alias Harness.GitFixture
  alias Harness.Project
  alias Harness.Verification.Check

  describe "%Project{}" do
    test "requires name, source, check_stacks, and roadmap_path" do
      stack = %CheckStack{name: :tiny, checks: [%Check{name: "a", command: "true", args: []}]}

      project = %Project{
        name: "demo",
        source: {:local, "/tmp/demo"},
        check_stacks: [stack],
        roadmap_path: "/tmp/demo"
      }

      assert project.name == "demo"
      assert project.check_stacks == [stack]
      assert project.concurrency_cap == nil
      assert project.landing_policy == :manual
      assert project.semantic_gate == :auto_land_only
    end

    test "accepts a {:github, url} source" do
      project = %Project{
        name: "demo",
        source: {:github, "https://github.com/example/demo.git"},
        check_stacks: [%CheckStack{name: :tiny, checks: []}],
        roadmap_path: "/tmp/demo"
      }

      assert project.source == {:github, "https://github.com/example/demo.git"}
    end

    test "repo_path/1 expands a local source path" do
      project = %Project{
        name: "demo",
        source: {:local, "relative/repo"},
        check_stacks: [%CheckStack{name: :tiny, checks: []}],
        roadmap_path: "relative/repo"
      }

      assert Project.repo_path(project) == Path.expand("relative/repo")
    end

    test "repo_path/2 returns the cache path for a github source" do
      project = %Project{
        name: "demo",
        source: {:github, "https://github.com/example/demo.git"},
        check_stacks: [%CheckStack{name: :tiny, checks: []}],
        roadmap_path: "/tmp/demo"
      }

      cache_root = GitFixture.tmp_base(name: "cache")
      assert Project.repo_path(project, cache_root: cache_root) == Path.join(cache_root, "demo")
    end

    test "ensure_local_repo/1 is a no-op for local sources" do
      project = %Project{
        name: "demo",
        source: {:local, "/tmp/demo"},
        check_stacks: [%CheckStack{name: :tiny, checks: []}],
        roadmap_path: "/tmp/demo"
      }

      assert {:ok, "/tmp/demo"} = Project.ensure_local_repo(project)
    end
  end
end
