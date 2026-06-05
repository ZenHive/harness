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

    test "threads the structured body and acceptance_criteria onto the Item" do
      assert {:ok, %Item{} = item} = Roadmap.ingest({:id, "1"}, project_root: @sample)
      assert item.body =~ "A fixture task that has already shipped"
      assert item.acceptance_criteria == ["The finished task is fetchable by id"]
    end

    test "renders the prompt for the requested agent" do
      assert {:ok, %Item{agent: :codex} = item} =
               Roadmap.ingest({:id, "1"}, project_root: @sample, agent: :codex)

      assert item.prompt =~ "Target: codex"
    end

    test "renders natively for every harness adapter, including grok/antigravity/pi" do
      # rmap's widened `delegate --to` renders a native prompt for all six —
      # no claude-rendered two-step. The agent atom flows straight through and
      # the rendered Target matches.
      for agent <- [:claude, :codex, :cursor, :grok, :antigravity, :pi] do
        assert {:ok, %Item{agent: ^agent} = item} =
                 Roadmap.ingest({:id, "1"}, project_root: @sample, agent: agent)

        assert item.prompt =~ "Target: #{agent}"
      end
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

    test "defaults acceptance_criteria to an empty list and body to nil when absent" do
      # A task whose JSON carries neither key — ingestion must not crash and the
      # Item must carry [] / nil rather than the missing-key value.
      stub =
        stub_script("""
        case "$1" in
          show) echo '{"id":"7","title":"Bare task"}' ;;
          delegate) echo 'rendered prompt' ;;
        esac
        """)

      assert {:ok, %Item{id: "7", body: nil, acceptance_criteria: []}} =
               Roadmap.ingest({:id, "7"}, project_root: @sample, rmap_bin: stub)
    end

    test "defaults acceptance_criteria to an empty list when rmap emits null" do
      stub =
        stub_script("""
        case "$1" in
          show) echo '{"id":"7","title":"Null criteria","acceptance_criteria":null}' ;;
          delegate) echo 'rendered prompt' ;;
        esac
        """)

      assert {:ok, %Item{id: "7", acceptance_criteria: []}} =
               Roadmap.ingest({:id, "7"}, project_root: @sample, rmap_bin: stub)
    end

    test "carries the task model field onto the ingested item" do
      stub =
        stub_script("""
        case "$1" in
          show) echo '{"id":"7","title":"Pinned model","model":"gpt-5.4"}' ;;
          delegate) echo 'rendered prompt' ;;
        esac
        """)

      assert {:ok, %Item{id: "7", model: "gpt-5.4"}} =
               Roadmap.ingest({:id, "7"}, project_root: @sample, rmap_bin: stub)
    end

    test "defaults model to nil when the task omits it" do
      stub =
        stub_script("""
        case "$1" in
          show) echo '{"id":"7","title":"Bare task"}' ;;
          delegate) echo 'rendered prompt' ;;
        esac
        """)

      assert {:ok, %Item{id: "7", model: nil}} =
               Roadmap.ingest({:id, "7"}, project_root: @sample, rmap_bin: stub)
    end
  end

  describe "ingest/2 next" do
    test "fetches the next pending task" do
      assert {:ok, %Item{id: "2"} = item} = Roadmap.ingest(:next, project_root: @sample)
      assert item.title == "The next pending fixture task"
      assert item.prompt =~ "# Task 2"
    end

    test "threads body and acceptance_criteria for the next pending task" do
      assert {:ok, %Item{id: "2"} = item} = Roadmap.ingest(:next, project_root: @sample)
      assert item.body =~ "The single pending fixture task"
      assert item.acceptance_criteria == ["The pending task is the one rmap next returns"]
    end

    test "returns no_pending_task when nothing is pending" do
      assert {:error, :no_pending_task} = Roadmap.ingest(:next, project_root: @empty)
    end
  end

  describe "ingest/2 errors" do
    test "rejects :droid — rmap renders it but harness has no executor for it" do
      # rmap's `delegate --to` accepts droid, but harness ships no Droid adapter,
      # so ingestion rejects it on the ingest surface rather than rendering a
      # prompt that nothing can run.
      assert {:error, {:invalid_agent, :droid}} =
               Roadmap.ingest({:id, "1"}, project_root: @sample, agent: :droid)
    end

    test "rejects an unknown agent before shelling out" do
      assert {:error, {:invalid_agent, :nope}} =
               Roadmap.ingest({:id, "1"}, project_root: @sample, agent: :nope)
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
      # A stub that exits with a code outside rmap's structured set (3 =
      # task-not-found, 4 = invalid-roadmap) — falls through to the generic branch.
      stub = stub_script("exit 5")

      assert {:error, {:rmap_failed, _args, 5, ""}} =
               Roadmap.ingest({:id, "1"}, project_root: @sample, rmap_bin: stub)
    end

    test "honors project.roadmap_path when given a project" do
      project = ProjectFixture.from_repo(@sample, roadmap_path: @sample)

      assert {:ok, %Item{id: "1"} = item} = Roadmap.ingest({:id, "1"}, project: project)
      assert is_binary(item.prompt)
      assert item.prompt != ""
    end
  end

  describe "ready/1" do
    test "decodes the dispatchable set as a bare array of routing rows" do
      stub =
        stub_script("""
        if [ "$1 $2 $3 $4" != "ready --dispatchable --fields id,assignee,markers" ]; then
          echo "unexpected args: $*" >&2
          exit 42
        fi
        echo '[{"id":"7","assignee":"codex","markers":[]},{"id":"8","assignee":null,"markers":["bug"]}]'
        """)

      assert {:ok, [%{"id" => "7", "assignee" => "codex"}, %{"id" => "8", "assignee" => nil}]} =
               Roadmap.ready(project_root: @sample, rmap_bin: stub)
    end

    test "an empty dispatchable set decodes to []" do
      stub = stub_script("echo '[]'")

      assert {:ok, []} = Roadmap.ready(project_root: @sample, rmap_bin: stub)
    end

    test "reports rmap_bad_output when ready emits non-array JSON" do
      stub = stub_script("echo '{}'")

      assert {:error, {:rmap_bad_output, {:unexpected_json, %{}}}} =
               Roadmap.ready(project_root: @sample, rmap_bin: stub)
    end

    test "reports rmap_not_found when the binary is absent" do
      assert {:error, {:rmap_not_found, "definitely-not-rmap-xyz"}} =
               Roadmap.ready(project_root: @sample, rmap_bin: "definitely-not-rmap-xyz")
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
