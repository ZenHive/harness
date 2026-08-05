defmodule Harness.ProjectTest do
  use ExUnit.Case, async: true

  alias Harness.GitFixture
  alias Harness.Project

  describe "%Project{}" do
    test "requires name, source, roadmap_path, and languages; everything else defaults" do
      project = %Project{
        name: "demo",
        source: {:local, "/tmp/demo"},
        roadmap_path: "/tmp/demo",
        languages: [:elixir]
      }

      assert project.name == "demo"
      assert project.languages == [:elixir]
      assert project.check_command == nil
      assert project.concurrency_cap == nil
      assert project.landing_policy == :manual
      assert project.roadmap_target_branch == nil
      assert project.target_branch == nil
      assert project.pollution_allowlist == nil
      assert project.reviewer == nil
      assert project.test_db_isolation_env == nil
    end

    test "carries the reviewer's check-command hint as free text" do
      project = %Project{
        name: "demo",
        source: {:local, "/tmp/demo"},
        roadmap_path: "/tmp/demo",
        languages: [:elixir],
        check_command: "mix precommit"
      }

      assert project.check_command == "mix precommit"
    end

    test "carries an optional per-project test DB isolation env override" do
      project = %Project{
        name: "demo",
        source: {:local, "/tmp/demo"},
        roadmap_path: "/tmp/demo",
        languages: [:elixir],
        test_db_isolation_env: "APP_TEST_PARTITION"
      }

      assert project.test_db_isolation_env == "APP_TEST_PARTITION"
    end

    test "carries an explicit roadmap repository branch independently of the code branch" do
      project = %Project{
        name: "demo",
        source: {:local, "/tmp/code"},
        roadmap_path: "/tmp/workbench",
        roadmap_target_branch: "roadmap-main",
        languages: [:elixir],
        target_branch: "release"
      }

      assert project.roadmap_target_branch == "roadmap-main"
      assert project.target_branch == "release"
    end

    test "carries an explicit test DB isolation opt-out" do
      project = %Project{
        name: "demo",
        source: {:local, "/tmp/demo"},
        roadmap_path: "/tmp/demo",
        languages: [:elixir],
        test_db_isolation_env: false
      }

      assert project.test_db_isolation_env == false
    end

    test "accepts a {:github, url} source" do
      project = %Project{
        name: "demo",
        source: {:github, "https://github.com/example/demo.git"},
        roadmap_path: "/tmp/demo",
        languages: [:elixir]
      }

      assert project.source == {:github, "https://github.com/example/demo.git"}
    end

    test "repo_path/1 expands a local source path" do
      project = %Project{
        name: "demo",
        source: {:local, "relative/repo"},
        roadmap_path: "relative/repo",
        languages: [:elixir]
      }

      assert Project.repo_path(project) == Path.expand("relative/repo")
    end

    test "repo_path/2 returns the cache path for a github source" do
      project = %Project{
        name: "demo",
        source: {:github, "https://github.com/example/demo.git"},
        roadmap_path: "/tmp/demo",
        languages: [:elixir]
      }

      cache_root = GitFixture.tmp_base(name: "cache")
      assert Project.repo_path(project, cache_root: cache_root) == Path.join(cache_root, "demo")
    end

    test "ensure_local_repo/1 is a no-op for local sources" do
      project = %Project{
        name: "demo",
        source: {:local, "/tmp/demo"},
        roadmap_path: "/tmp/demo",
        languages: [:elixir]
      }

      assert {:ok, "/tmp/demo"} = Project.ensure_local_repo(project)
    end
  end

  describe "target_branch/1" do
    test "resolves a configured target branch" do
      project = %Project{
        name: "demo",
        source: {:local, "/tmp/demo"},
        roadmap_path: "/tmp/demo",
        languages: [:elixir],
        target_branch: "development"
      }

      assert {:ok, "development"} = Project.target_branch(project)
    end

    test "signals a skip when unset or empty" do
      base = %Project{
        name: "demo",
        source: {:local, "/tmp/demo"},
        roadmap_path: "/tmp/demo",
        languages: [:elixir]
      }

      assert {:skipped, :no_target_branch} = Project.target_branch(base)
      assert {:skipped, :no_target_branch} = Project.target_branch(%{base | target_branch: ""})
    end
  end
end
