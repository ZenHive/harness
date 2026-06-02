defmodule Harness.DispatchTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Claude
  alias Harness.AgentAdapter.Codex
  alias Harness.Batch.AgentEvaluation
  alias Harness.CapabilityScore
  alias Harness.Chat.Tools
  alias Harness.Dispatch
  alias Harness.FakeAdapter
  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.ResultStore
  alias Harness.ResultStore.File, as: FileStore
  alias Harness.Roadmap.Item
  alias Harness.Run
  alias Harness.Run.LogRecord
  alias Harness.Run.Result
  alias Harness.Verification.Check
  alias Harness.Verification.Result, as: CheckResult
  alias Harness.Verification.Verdict

  @reference_time ~U[2026-06-01 12:00:00Z]

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

    test "defaults the adapter to recommendation and falls back through project lookup" do
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

    test "defaults the adapter to recommendation and reaches project lookup" do
      assert {:error, {:unknown_project, "__no_such_project__"}} =
               Dispatch.await("__no_such_project__", "next")
    end

    test "rejects a non-positive timeout via the guard" do
      assert_raise FunctionClauseError, fn ->
        Dispatch.await("any-project", "next", "claude", 0)
      end
    end
  end

  describe "review_green per-dispatch override surface (Tasks 123/162)" do
    # The force-on threading (start_run review_green: true routing a green verdict
    # to the cross-family reviewer regardless of the project setting) is proven at
    # the Run level in Harness.RunTest; here we assert the JSON-native surface
    # exposes the override on both dispatch tools so an MCP/chat orchestrator can
    # set it.
    for tool <- [:task, :await] do
      test "dispatch__#{tool} surfaces a review_green value param defaulting to false" do
        entry = Enum.find(Dispatch.__api__(), &match?(%{name: unquote(tool)}, &1))

        assert :review_green in entry.param_order

        param = entry.hints.params.review_green
        assert param.kind == :value
        assert param.default == false
        assert param.description =~ "cross-family reviewer pass"
      end
    end

    test "review_green=true threads a force-on override into the start_run opts" do
      opts = Dispatch.start_opts(self(), true, true)

      assert Keyword.fetch!(opts, :review_green) == true
      assert Keyword.fetch!(opts, :subscriber) == self()
    end

    test "review_green=false leaves the project-level setting in control (no override)" do
      opts = Dispatch.start_opts(nil, true, false)

      refute Keyword.has_key?(opts, :review_green)
    end

    test "run_start_opts threads the ingested item's model into start_run as requested_model" do
      item = %Item{id: "144", title: "t", prompt: "p", agent: :codex, model: "gpt-5.4"}

      assert Keyword.fetch!(Dispatch.run_start_opts(item, self(), true, false), :requested_model) ==
               "gpt-5.4"
    end

    test "run_start_opts omits requested_model when the item carries none" do
      item = %Item{id: "144", title: "t", prompt: "p", agent: :codex}

      refute Keyword.has_key?(Dispatch.run_start_opts(item, nil, true, false), :requested_model)
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

    test "summarizes a settled run that carries no verdict" do
      run_id = "run-no-verdict"

      send(self(), {:harness_run, run_id, %Result{run_id: run_id, task_id: "9", state: :done, reason: :passed}})

      assert {:ok, summary} = Dispatch.await_result(run_id, 1_000)

      # A nil verdict (verification never produced one) projects to nil, not a crash.
      assert summary.verdict == nil
      assert summary.state == :done
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

  describe "run observe/control — unknown run_id" do
    # The macro-generated tools and hand-written cancel all take a run_id
    # string. An unknown id exercises the delegate's {:error, :not_found} branch
    # (and cancel's idempotent no-op) without spawning a run.
    test "status passes {:error, :not_found} through for an unknown run_id" do
      assert {:error, :not_found} = Dispatch.status("__no_such_run__")
    end

    test "transcript passes {:error, :not_found} through for an unknown run_id" do
      assert {:error, :not_found} = Dispatch.transcript("__no_such_run__")
    end

    test "transcript_events passes {:error, :not_found} through for an unknown run_id" do
      assert {:error, :not_found} = Dispatch.transcript_events("__no_such_run__")
    end

    test "cancel is idempotent and returns a cancelled map for an unknown run_id" do
      assert {:ok, %{run_id: "__no_such_run__", cancelled: true}} =
               Dispatch.cancel("__no_such_run__")
    end
  end

  describe "run observe/control — live run summarizers" do
    setup do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()

      opts = [
        base_dir: base,
        adapter_opts: [command: :write],
        checks: [%Check{name: "ok", command: "true", args: []}],
        total_timeout: 30_000,
        idle_timeout: 10_000,
        lifetime_timeout: 30_000,
        verification_timeout: 10_000,
        # Generous linger so the settled run stays registered long enough to
        # observe through the Dispatch summarizers across several calls.
        terminal_linger: 5_000,
        max_repair_attempts: 0
      ]

      item = %Item{id: "8", title: "t", prompt: "do the thing", agent: :claude}

      {:ok, run_id, _pid} =
        Run.Supervisor.start_run(item, ProjectFixture.from_repo(repo), FakeAdapter, opts)

      assert_receive {:harness_run, ^run_id, %Result{state: :done}}, 5_000
      {:ok, run_id: run_id}
    end

    test "status projects the Run.Status snapshot into a JSON-safe map", %{run_id: run_id} do
      assert {:ok, summary} = Dispatch.status(run_id)

      assert summary.run_id == run_id
      assert summary.task_id == "8"
      assert summary.state == :done
      # The summarizer flattens the struct to a plain map of scalars.
      refute is_struct(summary)
      assert Map.has_key?(summary, :verdict_status)
      assert Map.has_key?(summary, :repair_attempts)
      assert Map.has_key?(summary, :worktree_path)
    end

    test "transcript projects buffer + seq", %{run_id: run_id} do
      assert {:ok, %{transcript: transcript, seq: seq}} = Dispatch.transcript(run_id)
      assert is_binary(transcript)
      assert is_integer(seq)
    end

    test "transcript_events flattens events to JSON-safe maps", %{run_id: run_id} do
      assert {:ok, %{events: events, seq: seq}} = Dispatch.transcript_events(run_id)
      assert is_list(events)
      assert is_integer(seq)
      assert Enum.all?(events, &is_map/1)
    end
  end

  describe "bundle/2 fan-out resolution" do
    # Adapter resolution runs before project lookup and before rmap/Oban, so the
    # three rejection shapes are provable without a registered project or a DB.
    test "rejects an unknown adapter" do
      assert {:error, {:unknown_adapter, "bogus"}} = Dispatch.bundle("any-project", "bogus")
    end

    test "accepts grok now that rmap renders it natively (reaches project lookup)" do
      # grok used to be rejected as non-delegatable; rmap's widened delegate
      # vocabulary makes it a first-class bundle adapter, so resolution passes
      # and the next gate — project lookup — is what rejects this unregistered name.
      assert {:error, {:unknown_project, "any-project"}} = Dispatch.bundle("any-project", "grok")
    end

    test "returns unknown_project for an unregistered project on a delegatable adapter" do
      assert {:error, {:unknown_project, "__no_such_project__"}} =
               Dispatch.bundle("__no_such_project__", "claude")
    end

    test "defaults the adapter to claude and reaches project lookup" do
      assert {:error, {:unknown_project, "__no_such_project__"}} =
               Dispatch.bundle("__no_such_project__")
    end
  end

  describe "compare/4 A/B resolution" do
    # compare resolves adapter names before project lookup and before rmap, so an
    # empty/unknown adapter list and an unknown project all surface without a run.
    test "rejects an empty adapter list" do
      assert {:error, :no_adapters} = Dispatch.compare("any-project", "next", [])
    end

    test "rejects an unknown adapter in the list" do
      assert {:error, {:unknown_adapter, "bogus"}} =
               Dispatch.compare("any-project", "next", ["claude", "bogus"])
    end

    test "returns unknown_project for an unregistered project with valid adapters" do
      assert {:error, {:unknown_project, "__no_such_project__"}} =
               Dispatch.compare("__no_such_project__", "next", ["claude", "codex"])
    end
  end

  describe "summarize_comparison/1 projection" do
    # The projection seam (mirrors await_result/2) — tested with a hand-built
    # Comparison so the struct→JSON-safe-map shaping is covered without a live
    # A/B run. The crashed entry's tuple reason exercises the inspect fallback.
    test "projects entries to JSON-safe maps (modules inspected, token usage flattened, tuple reasons stringified)" do
      comparison = %AgentEvaluation.Comparison{
        batch_id: "batch-ab",
        task_id: "42",
        total: 2,
        max_concurrency: 2,
        entries: [
          %AgentEvaluation.Entry{
            adapter: Claude,
            run_id: "run-a",
            state: :done,
            reason: :passed,
            verdict: :pass,
            repair_attempts: 0,
            duration_ms: 1234,
            first_attempt_failed_check_count: 0,
            agent_diff_size: 12,
            token_usage: %Harness.TokenUsage{input: 5, output: 1, total: 6},
            result: %Result{run_id: "run-a", task_id: "42", state: :done, reason: :passed}
          },
          %AgentEvaluation.Entry{
            adapter: Codex,
            run_id: "run-b",
            state: :failed,
            reason: {:run_crashed, :boom},
            verdict: nil,
            repair_attempts: 1,
            duration_ms: nil,
            first_attempt_failed_check_count: 2,
            agent_diff_size: nil,
            token_usage: %Harness.TokenUsage{},
            result: %Result{run_id: "run-b", task_id: "42", state: :failed, reason: {:run_crashed, :boom}}
          }
        ]
      }

      assert %{batch_id: "batch-ab", task_id: "42", total: 2, max_concurrency: 2, entries: [a, b]} =
               Dispatch.summarize_comparison(comparison)

      # Module → readable string; token usage struct → plain map; scalar reason kept.
      assert a.adapter == "Harness.AgentAdapter.Claude"
      assert a.state == :done
      assert a.reason == :passed
      assert a.verdict == :pass
      assert a.duration_ms == 1234
      # Flattened to a plain map (extra TokenUsage fields like cache_* ride along).
      assert %{input: 5, output: 1, total: 6} = a.token_usage
      refute is_struct(a.token_usage)

      # Tuple reason → inspect fallback so the whole map stays JSON-encodable.
      assert b.adapter == "Harness.AgentAdapter.Codex"
      assert b.reason == "{:run_crashed, :boom}"
      assert b.verdict == nil
    end
  end

  describe "verdict_detail/1 settled-run failure output" do
    # summarize_verdict_detail/1 is the projection seam (mirrors
    # summarize_comparison/1) — covered with a real LogRecord built by
    # from_result/2 so the failed-check capture is exercised end to end. Unlike
    # the await summary (which drops check output), verdict_detail SURFACES it.
    test "surfaces the failing checks' captured output (the await summary drops it)" do
      record = LogRecord.from_result(red_result("run-vd-1"), batch_id: "b", adapter: Claude, duration_ms: 1)

      detail = Dispatch.summarize_verdict_detail(record)

      assert detail.run_id == "run-vd-1"
      assert detail.verdict == :fail
      assert detail.failed_checks == ["credo"]
      assert %{"credo" => %{output: output, truncated: false}} = detail.checks
      assert output =~ "captured output"
      # A passing check carries no entry — only failures are kept.
      refute Map.has_key?(detail.checks, "tests")
    end

    test "returns :not_found for an unknown/unrecorded run_id" do
      assert {:error, :not_found} = Dispatch.verdict_detail("__no_such_run__")
    end

    test "loads a persisted record from the result store and projects it" do
      run_id = "run-vd-store-#{System.unique_integer([:positive])}"
      record = LogRecord.from_result(red_result(run_id), batch_id: "b", adapter: Claude, duration_ms: 1)
      :ok = ResultStore.record_run(record)

      assert {:ok, detail} = Dispatch.verdict_detail(run_id)
      assert detail.run_id == run_id
      assert detail.verdict == :fail
      assert detail.failed_checks == ["credo"]
      assert %{"credo" => %{output: _, truncated: false}} = detail.checks
    end
  end

  describe "recommend/2 routing advice" do
    setup do
      root =
        Path.join(
          System.tmp_dir!(),
          "harness_dispatch_recommend_test_#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, store: {FileStore, root: root}}
    end

    test "returns ranked advice over the driver surface", %{store: store} do
      assert :ok = ResultStore.save_capability_score(score(:codex, :otp, 800.0), store)
      assert :ok = ResultStore.save_capability_score(score(:claude, :otp, 700.0), store)

      assert {:ok, recommendation} =
               Dispatch.recommend("otp",
                 agents: [:claude, :codex],
                 reference_time: @reference_time,
                 result_store: store
               )

      assert recommendation.agent == :codex
      assert recommendation.strategy == :exploit
      assert [%{agent: :codex} | _] = recommendation.ranked
    end

    test "the dispatch recommendation helper resolves the recommended adapter for next-task routing", %{store: store} do
      assert :ok = ResultStore.save_capability_score(score(:codex, :otp, 800.0), store)
      assert :ok = ResultStore.save_capability_score(score(:claude, :otp, 700.0), store)
      item = %Item{id: "120", title: "t", prompt: "p", agent: :claude, domains: [:otp]}

      assert {:ok, {Codex, :codex}} =
               Dispatch.recommended_adapter_for_item("recommend", item,
                 agents: [:claude, :codex],
                 reference_time: @reference_time,
                 result_store: store
               )
    end

    test "explicit adapters bypass recommendation", %{store: store} do
      item = %Item{id: "120", title: "t", prompt: "p", agent: :claude, domains: [:otp]}

      assert {:ok, {Claude, :claude}} =
               Dispatch.recommended_adapter_for_item("claude", item,
                 agents: [:claude, :codex],
                 reference_time: @reference_time,
                 result_store: store
               )
    end
  end

  describe "MCP surface" do
    test "dispatch-task is exposed as a flat, JSON-passable tool" do
      tools = Harness.Manifest.mcp_tools()
      tool = Enum.find(tools, &(&1.name == "dispatch-task"))

      assert tool, "dispatch-task should be on the MCP tool surface"

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

      for excluded <- ~w(supervisor-start_run batch-run batch-run_pinned batch-dispatch agent_evaluation-compare) do
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

    test "dispatch-await is exposed as a flat, JSON-passable tool alongside dispatch-task" do
      tools = Harness.Manifest.mcp_tools()

      assert Enum.find(tools, &(&1.name == "dispatch-task")),
             "dispatch-task must remain on the MCP surface"

      tool = Enum.find(tools, &(&1.name == "dispatch-await"))
      assert tool, "dispatch-await should be on the MCP tool surface"

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

      assert %{module: Dispatch, function: :await} = registry["dispatch-await"]
      assert %{module: Dispatch, function: :task} = registry["dispatch-task"]
    end

    test "the run observe/control tools are on the MCP surface as run_id-string tools" do
      tools = Harness.Manifest.mcp_tools()

      for name <- ~w(dispatch-status dispatch-transcript dispatch-transcript_events dispatch-cancel) do
        tool = Enum.find(tools, &(&1.name == name))
        assert tool, "#{name} should be on the MCP tool surface"
        assert Map.has_key?(tool.inputSchema.properties, :run_id)
        assert tool.inputSchema.required == ["run_id"]
      end
    end

    test "the chat tool registry resolves the run observe/control tools to Harness.Dispatch" do
      registry = Tools.build()

      assert %{module: Dispatch, function: :status} = registry["dispatch-status"]
      assert %{module: Dispatch, function: :transcript} = registry["dispatch-transcript"]
      assert %{module: Dispatch, function: :transcript_events} = registry["dispatch-transcript_events"]
      assert %{module: Dispatch, function: :cancel} = registry["dispatch-cancel"]
    end

    test "dispatch-bundle is exposed as a flat, JSON-passable tool" do
      tool = Enum.find(Harness.Manifest.mcp_tools(), &(&1.name == "dispatch-bundle"))
      assert tool, "dispatch-bundle should be on the MCP tool surface"

      props = tool.inputSchema.properties
      assert Map.has_key?(props, :project_name)
      assert Map.has_key?(props, :adapter)

      # Only project_name is undefaulted; adapter defaults to "claude".
      assert tool.inputSchema.required == ["project_name"]
    end

    test "dispatch-compare is exposed as a flat, JSON-passable tool" do
      tool = Enum.find(Harness.Manifest.mcp_tools(), &(&1.name == "dispatch-compare"))
      assert tool, "dispatch-compare should be on the MCP tool surface"

      props = tool.inputSchema.properties
      assert Map.has_key?(props, :project_name)
      assert Map.has_key?(props, :task)
      assert Map.has_key?(props, :adapters)
      assert Map.has_key?(props, :scrub_anthropic_key)

      # scrub_anthropic_key defaults; the other three are required.
      assert Enum.sort(tool.inputSchema.required) == ["adapters", "project_name", "task"]
    end

    test "the chat tool registry resolves the fan-out tools to Harness.Dispatch" do
      registry = Tools.build()

      assert %{module: Dispatch, function: :bundle} = registry["dispatch-bundle"]
      assert %{module: Dispatch, function: :compare} = registry["dispatch-compare"]
    end

    test "dispatch-verdict_detail is exposed as a run_id-string tool" do
      tool = Enum.find(Harness.Manifest.mcp_tools(), &(&1.name == "dispatch-verdict_detail"))
      assert tool, "dispatch-verdict_detail should be on the MCP tool surface"

      assert Map.has_key?(tool.inputSchema.properties, :run_id)
      assert tool.inputSchema.required == ["run_id"]
    end

    test "the chat tool registry resolves dispatch-verdict_detail to Harness.Dispatch" do
      registry = Tools.build()

      assert %{module: Dispatch, function: :verdict_detail} = registry["dispatch-verdict_detail"]
    end

    test "dispatch-recommend is exposed as the public routing advice tool" do
      tool = Enum.find(Harness.Manifest.mcp_tools(), &(&1.name == "dispatch-recommend"))
      assert tool, "dispatch-recommend should be on the MCP tool surface"

      props = tool.inputSchema.properties
      assert Map.has_key?(props, :domain)
      assert Map.has_key?(props, :opts)
      assert tool.inputSchema.required == ["domain"]

      registry = Tools.build()
      assert %{module: Dispatch, function: :recommend} = registry["dispatch-recommend"]
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

  defp score(agent, domain, composite_score) do
    %CapabilityScore{
      agent: agent,
      domain: domain,
      corpus_version: "test-v1",
      scored_at: ~U[2026-05-30 00:00:00Z],
      run_count: 1,
      success_rate: composite_score / 1_000,
      cost_to_green: 100.0,
      mean_repair_attempts: 0.0,
      mean_first_attempt_failed_check_count: 0.0,
      composite_score: composite_score,
      raw_metrics: []
    }
  end
end
