defmodule Harness.Cron.OrchestratorLiveTest do
  use ExUnit.Case, async: false

  alias Harness.Cron.Orchestrator
  alias Harness.Dispatch.Attempts
  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.ResultStore
  alias Harness.ResultStore.Memory
  alias Harness.Roadmap
  alias Harness.Run.LogRecord

  @moduletag :integration
  @moduletag :tmp_dir
  @moduletag timeout: 360_000

  # Runs only the planner, never dispatch/Oban. Evidence survives scratch cleanup.
  setup %{tmp_dir: dir} do
    executable = System.find_executable("codex")
    assert executable, "Install and authenticate the real codex CLI before running the live planner test"
    assert System.find_executable("python3"), "The planner evidence wrapper requires python3"
    keys = [:cron_orchestrator, :cron_polling, :agent_model, :result_store]
    previous = Map.new(keys, &{&1, Application.fetch_env(:harness, &1)})
    env_keys = ["PATH", "PLANNER_REAL_CODEX", "PLANNER_EVIDENCE_DIR"]
    previous_env = Map.new(env_keys, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:harness, key, value)
          :error -> Application.delete_env(:harness, key)
        end
      end

      for {key, value} <- previous_env do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    wrapper = Path.join(dir, "codex")
    File.cp!("test/fixtures/cron_planner/codex_capture.py", wrapper)
    File.chmod!(wrapper, 0o755)
    System.put_env("PLANNER_REAL_CODEX", executable)
    System.put_env("PATH", dir <> ":" <> System.fetch_env!("PATH"))
    Application.delete_env(:harness, :cron_orchestrator)
    Application.put_env(:harness, :cron_polling, orchestrator_adapter: :codex)
    Application.put_env(:harness, :agent_model, codex: "gpt-6-astra")
    Application.put_env(:harness, :result_store, {Memory, scope: make_ref()})

    %{repo: repo} = GitFixture.init_with_origin()
    project = ProjectFixture.from_repo(repo, name: "planner-live", concurrency_cap: 2, target_branch: "main")

    tasks =
      for id <- ["1", "2"] do
        %{
          "id" => id,
          "title" => "Implement independent runtime subsystem #{id}",
          "body" => "Implement the specified runtime subsystem with independent review and integration tests.",
          "assignee" => "codex",
          "model" => "gpt-6-astra",
          "touches" => ["lib/subsystem_#{id}.ex"],
          "scores" => %{"d" => 5, "b" => 8, "u" => 8}
        }
      end

    %{project: project, tasks: tasks}
  end

  test "verified empty history dispatches both eligible tasks from non-Git scratch", ctx do
    assert {:ok, tasks} = Attempts.attach(ctx.project, ctx.tasks)
    assert Enum.all?(tasks, &(&1["attempts"] == []))
    plan = live_plan(ctx, "empty-history")
    assert plan.skip == []
    assert Enum.sort(Enum.map(plan.dispatch, & &1.task_id)) == ["1", "2"]

    for entry <- plan.dispatch do
      assert entry.action == "fresh"
      assert entry.adapter == "codex"
      assert entry.model == "gpt-6-astra"
      assert is_binary(entry.reason) and entry.reason != ""
      refute Map.has_key?(entry, :source_run_id)
    end
  end

  test "prior work without required Git evidence remains deferred", ctx do
    for task <- ctx.tasks do
      :ok =
        ResultStore.record_run(%LogRecord{
          batch_id: "fixture",
          run_id: "prior-#{task["id"]}",
          task_id: task["id"],
          task_ids: [task["id"]],
          project_name: ctx.project.name,
          task_fingerprint: Roadmap.task_fingerprint(task),
          adapter: Harness.AgentAdapter.Codex,
          state: :failed,
          reason: :review_rejected,
          duration_ms: 1,
          agent_diff_size: 120,
          review_report: "Useful implementation committed; fix the failing boundary test.",
          verdict: :reject
        })
    end

    assert {:ok, tasks} = Attempts.attach(ctx.project, ctx.tasks)
    assert Enum.all?(tasks, &match?([%{"git" => %{"error" => _}}], &1["attempts"]))
    plan = live_plan(ctx, "missing-recovery-evidence")
    assert plan.dispatch == []
    assert Enum.sort(Enum.map(plan.skip, & &1.task_id)) == ["1", "2"]
    assert Enum.all?(plan.skip, &(&1.disposition == "defer" and &1.reason != ""))
  end

  defp live_plan(ctx, scenario) do
    root = System.get_env("PLANNER_TEST_EVIDENCE_ROOT") || ".harness/planner-live"
    evidence = Path.expand(Path.join(root, scenario <> "-#{System.os_time(:nanosecond)}"))
    System.put_env("PLANNER_EVIDENCE_DIR", evidence)
    result = Orchestrator.plan(ctx.project, ctx.tasks)
    IO.puts("Live planner evidence: #{evidence}")
    assert {:ok, plan} = result
    invocation = evidence |> Path.join("invocation.json") |> File.read!() |> Jason.decode!()
    assert invocation["git_exit"] != 0
    assert Path.basename(invocation["cwd"]) =~ "harness-cron-planner-live-"
    refute File.exists?(invocation["cwd"])
    assert File.read!(Path.join(evidence, "exit-status.txt")) == "0"
    plan
  end
end
