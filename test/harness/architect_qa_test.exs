defmodule Harness.ArchitectQATest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Claude
  alias Harness.ArchitectQA
  alias Harness.Chat.Tools
  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.Run.LogRecord
  alias Harness.Run.Result
  alias Harness.Run.Review

  describe "status/1 and mark_done/2" do
    setup do
      project =
        ProjectFixture.from_repo(GitFixture.init_repo(),
          name: "architect-qa-#{System.unique_integer([:positive])}",
          roadmap_path: Path.expand("../fixtures/sample_roadmap", __DIR__),
          check_command: "mix check.dispatch"
        )

      :ok = ProjectRegistry.register(project)
      on_exit(fn -> ProjectRegistry.unregister(project.name) end)

      {:ok, project: project}
    end

    test "does not require Architect/QA when the project has no landed SHA", %{project: project} do
      assert {:ok, status} = ArchitectQA.status(project.name)

      refute status.required
      assert status.latest_landed_sha == nil
      assert status.check_command == "mix precommit.full"
    end

    test "requires Architect/QA for a newly landed SHA and clears after marking done", %{project: project} do
      :ok = record_landed(project.name, "run-qa-1", "sha-one")

      assert {:ok, status} = ArchitectQA.status(project.name)
      assert status.required
      assert status.latest_landed_sha == "sha-one"
      assert status.last_reviewed_sha == nil

      assert {:ok, reviewed} = ArchitectQA.mark_done(project.name)

      refute reviewed.required
      assert reviewed.latest_landed_sha == "sha-one"
      assert reviewed.last_reviewed_sha == "sha-one"
      assert is_binary(reviewed.reviewed_at)
    end

    test "requires Architect/QA again when a newer landed SHA appears", %{project: project} do
      :ok = record_landed(project.name, "run-qa-2", "sha-old")
      assert {:ok, %{required: false}} = ArchitectQA.mark_done(project.name)

      :ok = record_landed(project.name, "run-qa-3", "sha-new")

      assert {:ok, status} = ArchitectQA.status(project.name)
      assert status.required
      assert status.latest_landed_sha == "sha-new"
      assert status.last_reviewed_sha == "sha-old"
    end
  end

  describe "MCP surface" do
    test "exposes Architect/QA status and mark tools" do
      names = Enum.map(Harness.Manifest.mcp_tools(), & &1.name)

      assert "architect_qa-status" in names
      assert "architect_qa-mark_done" in names
      assert %{module: ArchitectQA, function: :status} = Tools.build()["architect_qa-status"]
      assert %{module: ArchitectQA, function: :mark_done} = Tools.build()["architect_qa-mark_done"]
    end
  end

  defp record_landed(project_name, run_id, sha) do
    %Result{
      run_id: run_id,
      task_id: "25",
      state: :done,
      reason: :approved,
      review: %Review{verdict: :approve, report: "approved"}
    }
    |> LogRecord.from_result(
      batch_id: "b",
      project_name: project_name,
      adapter: Claude,
      duration_ms: 1
    )
    |> Map.put(:landed_sha, sha)
    |> ResultStore.record_run()
  end
end
