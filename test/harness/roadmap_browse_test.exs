defmodule Harness.RoadmapBrowseTest do
  # async: false — exercises the global ProjectRegistry, which list/2 and
  # next_bundle/1 resolve project names against. Every registry-resetting test
  # in the suite is sync; this one joins them so it never overlaps an async run.
  use ExUnit.Case, async: false

  alias Harness.Chat.Tools
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.Roadmap

  # Static fixture roadmaps — `sample` has a done task ("1") and one pending
  # task ("2"), both in bundle "fixture"; `empty` has only a done task, so its
  # pending list and next bundle are empty.
  @sample Path.expand("../fixtures/sample_roadmap", __DIR__)
  @empty Path.expand("../fixtures/empty_roadmap", __DIR__)

  setup_all do
    if !System.find_executable("rmap") do
      flunk("""
      rmap CLI not found on PATH.

      Harness.Roadmap shells out to `rmap`. Install it (a Rust binary,
      `cargo install` from the rmap repo) and ensure it is on PATH.
      """)
    end

    :ok
  end

  setup do
    ProjectRegistry.reset()
    :ok = ProjectRegistry.register(ProjectFixture.from_repo(@sample, name: "browse-sample", roadmap_path: @sample))
    :ok = ProjectRegistry.register(ProjectFixture.from_repo(@empty, name: "browse-empty", roadmap_path: @empty))
    :ok
  end

  describe "list/2" do
    test "returns every task as structured data, resolving the project by name" do
      assert {:ok, tasks} = Roadmap.list("browse-sample")
      assert Enum.map(tasks, & &1["id"]) == ["1", "2"]

      task = Enum.find(tasks, &(&1["id"] == "2"))
      assert task["title"] == "The next pending fixture task"
      assert task["status"] == "pending"
      assert task["bundle"] == "fixture"
      assert task["eff"] == 2.33
    end

    test "filters by status when given one" do
      assert {:ok, [%{"id" => "2", "status" => "pending"}]} = Roadmap.list("browse-sample", "pending")
    end

    test "returns an empty list when the status filter matches nothing" do
      assert {:ok, []} = Roadmap.list("browse-empty", "pending")
    end

    test "errors with :unknown_project for an unregistered name" do
      assert {:error, {:unknown_project, "nope-xyz"}} = Roadmap.list("nope-xyz")
    end

    test "dispatches positionally through the chat tool registry (descripex param_order)" do
      # Regression: before descripex 0.7's param_order, Chat.Tools ordered apply/3
      # args by Map.keys (hash order), so a hash that placed :status first sent the
      # status value into the project_name slot — `{:unknown_project, "pending"}`.
      registry = Tools.build()

      assert {:ok, {:ok, [%{"id" => "2", "status" => "pending"}]}} =
               Tools.dispatch(registry, "roadmap__list", %{
                 "project_name" => "browse-sample",
                 "status" => "pending"
               })
    end
  end

  describe "next_bundle/1" do
    test "returns the bundle metadata and its pending tasks" do
      assert {:ok, %{bundle: bundle, tasks: tasks}} = Roadmap.next_bundle("browse-sample")
      assert bundle["name"] == "fixture"
      assert bundle["phase"] == 1
      assert Enum.map(tasks, & &1["id"]) == ["2"]
    end

    test "returns a nil bundle and empty tasks when nothing is pending" do
      assert {:ok, %{bundle: nil, tasks: []}} = Roadmap.next_bundle("browse-empty")
    end

    test "errors with :unknown_project for an unregistered name" do
      assert {:error, {:unknown_project, "nope-xyz"}} = Roadmap.next_bundle("nope-xyz")
    end
  end
end
