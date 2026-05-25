defmodule Harness.ProjectTest do
  use ExUnit.Case, async: true

  alias Harness.CheckStack
  alias Harness.Project
  alias Harness.Verification.Check

  describe "%Project{}" do
    test "requires name, source, check_stack, and roadmap_path" do
      stack = %CheckStack{name: :tiny, checks: [%Check{name: "a", command: "true", args: []}]}

      project = %Project{
        name: "demo",
        source: {:local, "/tmp/demo"},
        check_stack: stack,
        roadmap_path: "/tmp/demo"
      }

      assert project.name == "demo"
      assert project.concurrency_cap == nil
    end

    test "repo_path/1 expands a local source path" do
      project = %Project{
        name: "demo",
        source: {:local, "relative/repo"},
        check_stack: %CheckStack{name: :tiny, checks: []},
        roadmap_path: "relative/repo"
      }

      assert Project.repo_path(project) == Path.expand("relative/repo")
    end
  end
end
