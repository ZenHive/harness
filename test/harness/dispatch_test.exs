defmodule Harness.DispatchTest do
  use ExUnit.Case, async: true

  alias Harness.Chat.Tools
  alias Harness.Dispatch
  alias Harness.Run.Result
  alias Harness.Verification.Result, as: CheckResult
  alias Harness.Verification.Verdict

  describe "task/4 adapter resolution" do
    test "rejects an unknown adapter before touching the registry" do
      assert {:error, {:unknown_adapter, "bogus"}} =
               Dispatch.task("any-project", "next", "bogus")
    end

    # An unregistered project means adapter resolution already succeeded — so
    # reaching :unknown_project proves the adapter string mapped to a module.
    # This covers delegatable and non-delegatable executors alike, without
    # spawning a run.
    for adapter <- ~w(claude codex cursor grok antigravity pi) do
      test "resolves the #{adapter} adapter (reaches project lookup)" do
        assert {:error, {:unknown_project, "__no_such_project__"}} =
                 Dispatch.task("__no_such_project__", "next", unquote(adapter))
      end
    end

    test "defaults the adapter to claude" do
      assert {:error, {:unknown_project, "__no_such_project__"}} =
               Dispatch.task("__no_such_project__", "next")
    end
  end

  describe "task/4 project resolution" do
    test "returns unknown_project for an unregistered project" do
      assert {:error, {:unknown_project, "__no_such_project__"}} =
               Dispatch.task("__no_such_project__", "25", "claude")
    end
  end

  describe "await/5 dispatch resolution" do
    # await shares the resolve → ingest → start_run path with task/4, so the
    # same error shapes prove the wiring without spawning a run.
    test "rejects an unknown adapter before touching the registry" do
      assert {:error, {:unknown_adapter, "bogus"}} =
               Dispatch.await("any-project", "next", "bogus")
    end

    test "returns unknown_project for an unregistered project" do
      assert {:error, {:unknown_project, "__no_such_project__"}} =
               Dispatch.await("__no_such_project__", "25", "claude")
    end

    test "defaults the adapter to claude and reaches project lookup" do
      assert {:error, {:unknown_project, "__no_such_project__"}} =
               Dispatch.await("__no_such_project__", "next")
    end

    test "rejects a non-positive timeout via the guard" do
      assert_raise FunctionClauseError, fn ->
        Dispatch.await("any-project", "next", "claude", 0)
      end
    end
  end

  describe "await_result/2 settle path" do
    test "summarizes a green settled run delivered to the subscriber" do
      run_id = "run-test-green"

      send(self(), {:harness_run, run_id, green_result(run_id)})

      assert {:ok, summary} = Dispatch.await_result(run_id, 1_000)

      assert summary.run_id == run_id
      assert summary.task_id == "25"
      assert summary.state == :done
      assert summary.reason == :passed
      assert summary.passed
      assert summary.verdict.status == :pass
      assert summary.verdict.failed_checks == []
      assert [%{name: "tests", status: :pass}] = summary.verdict.checks
      # The compact summary must not carry the raw check output.
      refute Map.has_key?(hd(summary.verdict.checks), :output)
    end

    test "summarizes a red settled run with failed-check names" do
      run_id = "run-test-red"

      send(self(), {:harness_run, run_id, red_result(run_id)})

      assert {:ok, summary} = Dispatch.await_result(run_id, 1_000)

      assert summary.state == :failed
      assert summary.reason == :verification_red
      refute summary.passed
      assert summary.verdict.status == :fail
      assert summary.verdict.failed_checks == ["credo"]
    end

    test "ignores a result for a different run_id and times out" do
      send(self(), {:harness_run, "some-other-run", green_result("some-other-run")})

      assert {:ok, %{state: :timed_out, run_id: "run-awaited"}} =
               Dispatch.await_result("run-awaited", 30)
    end
  end

  describe "await_result/2 timeout path" do
    test "returns a structured timeout result when no result arrives" do
      assert {:ok, summary} = Dispatch.await_result("run-hung", 20)

      assert summary.run_id == "run-hung"
      assert summary.state == :timed_out
      assert summary.reason == :await_timeout
      refute summary.passed
      assert summary.timeout_ms == 20
      assert is_binary(summary.note)
    end
  end

  describe "MCP surface" do
    test "dispatch__task is exposed as a flat, JSON-passable tool" do
      tools = Harness.Manifest.mcp_tools()
      tool = Enum.find(tools, &(&1.name == "dispatch__task"))

      assert tool, "dispatch__task should be on the MCP tool surface"

      # Descripex.MCP keys `properties` by atom, `required` by string.
      props = tool.inputSchema.properties
      assert Map.has_key?(props, :project_name)
      assert Map.has_key?(props, :task)
      assert Map.has_key?(props, :adapter)
      assert Map.has_key?(props, :scrub_anthropic_key)

      # Required params are only the two with no default.
      assert Enum.sort(tool.inputSchema.required) == ["project_name", "task"]
    end

    test "excludes struct-arg tools a JSON orchestrator cannot drive" do
      names = Enum.map(Harness.Manifest.mcp_tools(), & &1.name)

      for excluded <- ~w(supervisor__start_run batch__run batch__run_pinned batch__dispatch agent_evaluation__compare) do
        refute excluded in names, "#{excluded} must not be on the MCP surface"
      end
    end

    test "the full Elixir/Manifest driver surface still carries the struct-arg modules" do
      modules = Harness.Manifest.modules()

      # The struct tools are excluded from the JSON tool list but remain part of
      # the in-process Elixir driver surface (project_eval / IEx).
      assert Harness.Run.Supervisor in modules
      assert Harness.Batch in modules
      assert function_exported?(Harness.Run.Supervisor, :start_run, 4)
      assert function_exported?(Harness.Batch, :run, 4)
    end

    test "dispatch__await is exposed as a flat, JSON-passable tool alongside dispatch__task" do
      tools = Harness.Manifest.mcp_tools()

      assert Enum.find(tools, &(&1.name == "dispatch__task")),
             "dispatch__task must remain on the MCP surface"

      tool = Enum.find(tools, &(&1.name == "dispatch__await"))
      assert tool, "dispatch__await should be on the MCP tool surface"

      props = tool.inputSchema.properties
      assert Map.has_key?(props, :project_name)
      assert Map.has_key?(props, :task)
      assert Map.has_key?(props, :adapter)
      assert Map.has_key?(props, :timeout_ms)
      assert Map.has_key?(props, :scrub_anthropic_key)

      # Only the two undefaulted params are required.
      assert Enum.sort(tool.inputSchema.required) == ["project_name", "task"]
    end

    test "the in-process chat tool registry resolves both dispatch tools to Harness.Dispatch" do
      registry = Tools.build()

      assert %{module: Dispatch, function: :await} = registry["dispatch__await"]
      assert %{module: Dispatch, function: :task} = registry["dispatch__task"]
    end
  end

  defp green_result(run_id) do
    %Result{
      run_id: run_id,
      task_id: "25",
      state: :done,
      reason: :passed,
      verdict: %Verdict{status: :pass, results: [check_result("tests", :pass)]},
      worktree_path: "/tmp/wt/#{run_id}",
      repair_attempts: 0,
      first_attempt_failed_check_count: 0,
      agent_diff_size: 12
    }
  end

  defp red_result(run_id) do
    %Result{
      run_id: run_id,
      task_id: "25",
      state: :failed,
      reason: :verification_red,
      verdict: %Verdict{status: :fail, results: [check_result("tests", :pass), check_result("credo", :fail)]},
      worktree_path: "/tmp/wt/#{run_id}",
      repair_attempts: 1,
      first_attempt_failed_check_count: 1,
      agent_diff_size: 5
    }
  end

  defp check_result(name, status) do
    %CheckResult{
      name: name,
      command: "mix #{name}",
      status: status,
      kind: :exited,
      exit_status: if(status == :pass, do: 0, else: 1),
      output: "captured output that must not leak into the summary"
    }
  end
end
