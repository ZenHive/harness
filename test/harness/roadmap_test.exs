defmodule Harness.RoadmapTest do
  use ExUnit.Case, async: true

  alias Harness.ProjectFixture
  alias Harness.Roadmap
  alias Harness.Roadmap.Item

  # Static fixture roadmaps — never the live repo roadmap, which drifts as
  # tasks ship. `sample` has a done task ("1") and one pending task ("2");
  # `empty` has only a done task, so `rmap next` finds nothing.
  @sample Path.expand("../fixtures/sample_roadmap", __DIR__)
  @empty Path.expand("../fixtures/empty_roadmap", __DIR__)

  setup_all do
    if !System.find_executable("rmap") do
      flunk("""
      rmap CLI not found on PATH.

      Harness.Roadmap shells out to `rmap` — the roadmap substrate. Install it
      (a Rust binary, `cargo install` from the rmap repo) and ensure it is on
      PATH before running this suite.
      """)
    end

    :ok
  end

  describe "ingest/2 by id" do
    test "fetches a task by id and renders its prompt" do
      assert {:ok, %Item{} = item} = Roadmap.ingest({:id, "1"}, project_root: @sample)
      assert item.id == "1"
      assert item.title == "A finished fixture task"
      assert item.agent == :claude
      assert item.prompt =~ "# Task 1"
      assert item.prompt =~ "## Acceptance criteria"
    end

    test "renders the prompt for the requested agent" do
      assert {:ok, %Item{agent: :codex} = item} =
               Roadmap.ingest({:id, "1"}, project_root: @sample, agent: :codex)

      assert item.prompt =~ "Target: codex"
    end

    test "returns task_not_found for an unknown id" do
      assert {:error, {:task_not_found, "999"}} =
               Roadmap.ingest({:id, "999"}, project_root: @sample)
    end

    test "coerces an integer task id to a string" do
      # A project whose tasks.toml keys tasks on integers (`id = 25`) makes rmap
      # emit a JSON integer id. Item.id is String.t() and the id flows into a
      # `rmap delegate <id>` arg, so ingest must normalize it. Regression: the
      # decode guard was `is_binary(id)` only, rejecting integer-keyed roadmaps.
      stub =
        stub_script("""
        case "$1" in
          show) echo '{"id":25,"title":"Integer-keyed task"}' ;;
          delegate) echo 'rendered prompt' ;;
        esac
        """)

      assert {:ok, %Item{id: "25", title: "Integer-keyed task"} = item} =
               Roadmap.ingest({:id, "25"}, project_root: @sample, rmap_bin: stub)

      assert item.prompt =~ "rendered prompt"
    end
  end

  describe "ingest/2 next" do
    test "fetches the next pending task" do
      assert {:ok, %Item{id: "2"} = item} = Roadmap.ingest(:next, project_root: @sample)
      assert item.title == "The next pending fixture task"
      assert item.prompt =~ "# Task 2"
    end

    test "returns no_pending_task when nothing is pending" do
      assert {:error, :no_pending_task} = Roadmap.ingest(:next, project_root: @empty)
    end
  end

  describe "ingest/2 errors" do
    test "rejects an unsupported agent before shelling out" do
      assert {:error, {:invalid_agent, :grok}} =
               Roadmap.ingest({:id, "1"}, project_root: @sample, agent: :grok)
    end

    test "rejects :antigravity — rmap delegate cannot render for it" do
      assert {:error, {:invalid_agent, :antigravity}} =
               Roadmap.ingest({:id, "1"}, project_root: @sample, agent: :antigravity)
    end

    test "rejects a malformed selector" do
      assert {:error, {:invalid_selector, {:id, 6}}} =
               Roadmap.ingest({:id, 6}, project_root: @sample)
    end

    test "reports rmap_not_found when the binary is absent" do
      assert {:error, {:rmap_not_found, "definitely-not-rmap-xyz"}} =
               Roadmap.ingest({:id, "1"}, project_root: @sample, rmap_bin: "definitely-not-rmap-xyz")
    end

    test "reports roadmap_not_found when the roadmap is unreachable" do
      assert {:error, :roadmap_not_found} =
               Roadmap.ingest({:id, "1"}, project_root: "/nonexistent/harness/project")
    end

    test "reports roadmap_not_found for an unreachable roadmap via :next" do
      assert {:error, :roadmap_not_found} =
               Roadmap.ingest(:next, project_root: "/nonexistent/harness/project")
    end

    test "reports rmap_bad_output when rmap output is not valid JSON" do
      # /bin/echo stands in for rmap: it exits 0 but emits non-JSON.
      assert {:error, {:rmap_bad_output, _reason}} =
               Roadmap.ingest({:id, "1"}, project_root: @sample, rmap_bin: "/bin/echo")
    end

    test "reports rmap_bad_output when rmap emits valid non-task JSON" do
      # A stub that exits 0 with a JSON array — valid JSON, but not a task map.
      stub = stub_script("echo '[]'")

      assert {:error, {:rmap_bad_output, {:unexpected_json, []}}} =
               Roadmap.ingest({:id, "1"}, project_root: @sample, rmap_bin: stub)
    end

    test "reports rmap_failed for an unclassified rmap failure" do
      # A stub that exits non-zero with no output — the failure matches neither
      # the task-not-found nor the invalid-TOML branch.
      stub = stub_script("exit 3")

      assert {:error, {:rmap_failed, _args, 3, ""}} =
               Roadmap.ingest({:id, "1"}, project_root: @sample, rmap_bin: stub)
    end

    test "honors project.roadmap_path when given a project" do
      project = ProjectFixture.from_repo(@sample, roadmap_path: @sample)

      assert {:ok, %Item{id: "1"} = item} = Roadmap.ingest({:id, "1"}, project: project)
      assert is_binary(item.prompt)
      assert item.prompt != ""
    end
  end

  describe "Item" do
    test "enforces all four fields" do
      assert_raise ArgumentError, fn -> struct!(Item, id: "1") end
    end
  end

  # Writes an executable `/bin/sh` stub standing in for `rmap`, cleaned up after
  # the test. `body` is the shell line(s) the stub runs.
  defp stub_script(body) do
    path = Path.join(System.tmp_dir!(), "rmap_stub_#{System.unique_integer([:positive])}")
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
