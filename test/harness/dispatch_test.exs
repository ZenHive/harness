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
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.ResultStore.File, as: FileStore
  alias Harness.Roadmap.Item
  alias Harness.Run
  alias Harness.Run.LogRecord
  alias Harness.Run.Result
  alias Harness.Run.Review
  alias Harness.TokenUsage

  @reference_time ~U[2026-06-01 12:00:00Z]

  defmodule RereviewCountingAdapter do
    @moduledoc false

    use Harness.AgentAdapter

    alias Harness.AgentAdapter
    alias Harness.AgentAdapter.Capabilities
    alias Harness.AgentAdapter.Invocation

    @impl AgentAdapter
    def capabilities, do: %Capabilities{}

    @impl AgentAdapter
    def rule_channel, do: :none

    @impl AgentAdapter
    def build_command(%Invocation{adapter_opts: opts, task_id: task_id}) do
      owner = Keyword.get(opts, :owner) || Application.get_env(:harness, :rereview_counting_owner)
      if owner, do: send(owner, {:rereview_adapter_invoked, task_id})

      if String.ends_with?(task_id, "-review") do
        review = Jason.encode!(%{verdict: "approve", report: "review-only approved"})

        {:ok,
         {"/bin/sh",
          [
            "-c",
            ~S(test -f prior_work.txt && mkdir -p .harness && printf '%s' "$1" > .harness/review.json),
            "harness-rereview-counting",
            review
          ], []}}
      else
        {:ok, {"/bin/sh", ["-c", ~S(echo implementer-ran > implementer_invoked.txt)], []}}
      end
    end
  end

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

  describe "start_opts/run_start_opts threading" do
    test "start_opts threads the subscriber and the ANTHROPIC_API_KEY scrub" do
      opts = Dispatch.start_opts(self(), true)

      assert Keyword.fetch!(opts, :subscriber) == self()
      assert Keyword.fetch!(opts, :env) == %{"ANTHROPIC_API_KEY" => false}
    end

    test "start_opts without a subscriber or scrub carries a nil subscriber and an empty env" do
      opts = Dispatch.start_opts(nil, false)

      assert Keyword.fetch!(opts, :subscriber) == nil
      assert Keyword.fetch!(opts, :env) == %{}
    end

    test "run_start_opts threads the ingested item's model into start_run as requested_model" do
      item = %Item{id: "144", title: "t", prompt: "p", agent: :codex, model: "gpt-5.4"}

      assert Keyword.fetch!(Dispatch.run_start_opts(item, self(), true), :requested_model) ==
               "gpt-5.4"
    end

    test "run_start_opts omits requested_model when the item carries none" do
      item = %Item{id: "144", title: "t", prompt: "p", agent: :codex}

      refute Keyword.has_key?(Dispatch.run_start_opts(item, nil, true), :requested_model)
    end
  end

  describe "await_result/2 settle path" do
    test "summarizes an approved settled run delivered to the subscriber" do
      run_id = "run-test-approved"

      send(self(), {:harness_run, run_id, approved_result(run_id)})

      assert {:ok, summary} = Dispatch.await_result(run_id, 1_000)

      assert summary.run_id == run_id
      assert summary.task_id == "25"
      assert summary.state == :done
      assert summary.reason == :approved
      assert summary.passed
      assert summary.agent_diff_size == 12
      assert summary.reviewer_diff_size == 0
      assert summary.worktree_path == "/tmp/wt/#{run_id}"
      assert summary.review.verdict == :approve
      assert summary.review.report == "looks good"
      assert summary.review.ratings == %{"code_quality" => 8}
    end

    test "summarizes a rejected settled run with the reviewer's report" do
      run_id = "run-test-rejected"

      send(self(), {:harness_run, run_id, rejected_result(run_id)})

      assert {:ok, summary} = Dispatch.await_result(run_id, 1_000)

      assert summary.state == :failed
      assert summary.reason == {:review_rejected, "nothing salvageable"}
      refute summary.passed
      assert summary.review.verdict == :reject
      assert summary.review.report == "nothing salvageable"
    end

    test "summarizes a settled run that carries no review" do
      run_id = "run-no-review"

      send(
        self(),
        {:harness_run, run_id, %Result{run_id: run_id, task_id: "9", state: :done, reason: :approved}}
      )

      assert {:ok, summary} = Dispatch.await_result(run_id, 1_000)

      # A nil review (run settled before the reviewer produced one) projects to
      # nil, not a crash.
      assert summary.review == nil
      assert summary.state == :done
    end

    test "ignores a result for a different run_id and times out" do
      send(self(), {:harness_run, "some-other-run", approved_result("some-other-run")})

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
        reviewer: FakeAdapter,
        reviewer_adapter_opts: [command: {:review, "approve"}],
        total_timeout: 30_000,
        idle_timeout: 10_000,
        lifetime_timeout: 30_000,
        # Generous linger so the settled run stays registered long enough to
        # observe through the Dispatch summarizers across several calls.
        terminal_linger: 5_000
      ]

      item = %Item{id: "8", title: "t", prompt: "do the thing", agent: :claude}

      {:ok, run_id, _pid} =
        Run.Supervisor.start_run(item, ProjectFixture.from_repo(repo), FakeAdapter, opts)

      assert_receive {:harness_run, ^run_id, %Result{state: :done}}, 10_000
      {:ok, run_id: run_id}
    end

    test "status projects the Run.Status snapshot into a JSON-safe map", %{run_id: run_id} do
      assert {:ok, summary} = Dispatch.status(run_id)

      assert summary.run_id == run_id
      assert summary.task_id == "8"
      assert summary.state == :done
      # The summarizer flattens the struct to a plain map of scalars.
      refute is_struct(summary)
      assert summary.review_verdict == :approve
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

  describe "run recovery — unknown run_id" do
    # hold/steer/resume delegate to Harness.Run by run_id; an unknown id
    # exercises the {:error, :not_found} pass-through without spawning a run.
    test "hold passes {:error, :not_found} through for an unknown run_id" do
      assert {:error, :not_found} = Dispatch.hold("__no_such_run__")
    end

    test "steer passes {:error, :not_found} through for an unknown run_id" do
      assert {:error, :not_found} = Dispatch.steer("__no_such_run__", "do X next")
    end

    test "resume passes {:error, :not_found} through for an unknown run_id" do
      assert {:error, :not_found} = Dispatch.resume("__no_such_run__")
    end
  end

  describe "register_project/6 — input validation" do
    # An invalid source_type is rejected by build_source before any registry
    # interaction, so this stays async-safe (no global registry mutation). The
    # registration round-trip lives in the async: false ProjectRegistry test.
    test "rejects an unknown source_type before touching the registry" do
      assert {:error, {:invalid_source_type, "ftp"}} =
               Dispatch.register_project("p", "ftp", "/tmp/p", "/tmp/p")
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
            reason: :approved,
            verdict: :approve,
            reviewer_diff_size: 0,
            duration_ms: 1234,
            agent_diff_size: 12,
            token_usage: %TokenUsage{input: 5, output: 1, total: 6},
            result: %Result{run_id: "run-a", task_id: "42", state: :done, reason: :approved}
          },
          %AgentEvaluation.Entry{
            adapter: Codex,
            run_id: "run-b",
            state: :failed,
            reason: {:run_crashed, :boom},
            verdict: nil,
            reviewer_diff_size: nil,
            duration_ms: nil,
            agent_diff_size: nil,
            token_usage: %TokenUsage{},
            result: %Result{run_id: "run-b", task_id: "42", state: :failed, reason: {:run_crashed, :boom}}
          }
        ]
      }

      assert %{batch_id: "batch-ab", task_id: "42", total: 2, max_concurrency: 2, entries: [a, b]} =
               Dispatch.summarize_comparison(comparison)

      # Module → readable string; token usage struct → plain map; scalar reason kept.
      assert a.adapter == "Harness.AgentAdapter.Claude"
      assert a.state == :done
      assert a.reason == :approved
      assert a.verdict == :approve
      assert a.reviewer_diff_size == 0
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

  describe "verdict_detail/1 settled-run reviewer output" do
    # summarize_verdict_detail/1 is the projection seam (mirrors
    # summarize_comparison/1) — covered with a real LogRecord built by
    # from_result/2 so the reviewer-artifact capture is exercised end to end.
    # Unlike the await summary, this surfaces the persisted record.
    test "surfaces the reviewer's verdict, report, and ratings" do
      record =
        LogRecord.from_result(rejected_result("run-vd-1"), batch_id: "b", adapter: Claude, duration_ms: 1)

      detail = Dispatch.summarize_verdict_detail(record)

      assert detail.run_id == "run-vd-1"
      assert detail.task_id == "25"
      assert detail.verdict == :reject
      assert detail.report == "nothing salvageable"
      assert detail.ratings == %{"code_quality" => 2}
    end

    test "returns :not_found for an unknown/unrecorded run_id" do
      assert {:error, :not_found} = Dispatch.verdict_detail("__no_such_run__")
    end

    test "loads a persisted record from the result store and projects it" do
      run_id = "run-vd-store-#{System.unique_integer([:positive])}"

      record =
        LogRecord.from_result(rejected_result(run_id), batch_id: "b", adapter: Claude, duration_ms: 1)

      :ok = ResultStore.record_run(record)

      assert {:ok, detail} = Dispatch.verdict_detail(run_id)
      assert detail.run_id == run_id
      assert detail.verdict == :reject
      assert detail.report == "nothing salvageable"
    end
  end

  describe "base_ref threading (Run.Supervisor.start_run → worktree_opts, end to end)" do
    test "a run started with :base_ref carves its worktree off that branch" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()
      default = repo |> GitFixture.git!(["rev-parse", "--abbrev-ref", "HEAD"]) |> String.trim()

      # A retained failed branch carrying a sentinel file the resumed run inherits.
      GitFixture.git!(repo, ["checkout", "-b", "harness/run-old"])
      File.write!(Path.join(repo, "sentinel.txt"), "prior work\n")
      GitFixture.git!(repo, ["add", "."])
      GitFixture.git!(repo, ["commit", "-m", "prior attempt"])
      GitFixture.git!(repo, ["checkout", default])

      opts = [
        base_dir: base,
        base_ref: "harness/run-old",
        adapter_opts: [command: :snapshot_worktree],
        reviewer: FakeAdapter,
        reviewer_adapter_opts: [command: {:review, "approve"}],
        total_timeout: 30_000,
        idle_timeout: 10_000,
        lifetime_timeout: 30_000
      ]

      item = %Item{id: "9", title: "t", prompt: "p", agent: :claude}

      {:ok, run_id, _pid} =
        Run.Supervisor.start_run(item, ProjectFixture.from_repo(repo), FakeAdapter, opts)

      assert_receive {:harness_run, ^run_id, %Result{state: :done}}, 10_000

      # :snapshot_worktree commits the agent's cwd listing; it shows sentinel.txt,
      # proving the new worktree was carved off harness/run-old, not the default.
      {listing, 0} = System.cmd("git", ["-C", repo, "show", "harness/#{run_id}:agent-saw.txt"])
      assert listing =~ "sentinel.txt"
    end
  end

  describe "resume_failed/2 — failed-run recovery (record guards)" do
    test "returns :not_found for an unknown/unrecorded run_id" do
      assert {:error, :not_found} = Dispatch.resume_failed("__no_such_run__")
    end

    test "returns :not_failed for a settled run that did not fail" do
      run_id = "run-resume-done-#{System.unique_integer([:positive])}"

      record =
        LogRecord.from_result(approved_result(run_id), batch_id: "b", adapter: Claude, duration_ms: 1)

      :ok = ResultStore.record_run(record)

      assert {:error, :not_failed} = Dispatch.resume_failed(run_id)
    end
  end

  describe "resume_adapter/2 (resume agent selection)" do
    test "reuses the originally-recorded agent by default" do
      assert Dispatch.resume_adapter(log_record(agent: :codex), false) == "codex"
    end

    test "falls back to the recommend sentinel when no agent was recorded" do
      assert Dispatch.resume_adapter(log_record(agent: nil), false) == "recommend"
    end

    test "escalate routes through recommend regardless of the original agent" do
      assert Dispatch.resume_adapter(log_record(agent: :codex), true) == "recommend"
    end
  end

  describe "resume_item/2 (failure report injection)" do
    test "appends the reviewer report to the prompt, preserving the original" do
      resumed = Dispatch.resume_item(item("ORIGINAL"), log_record(review_report: "fix the flaky test"))

      assert resumed.prompt =~ "ORIGINAL"
      assert resumed.prompt =~ "Prior attempt failed"
      assert resumed.prompt =~ "fix the flaky test"
    end

    test "falls back to the failure reason text when no reviewer report exists" do
      record = log_record(review_report: nil, reason: {:review_stuck, "reviewer wrote no verdict"})
      resumed = Dispatch.resume_item(item("ORIGINAL"), record)

      assert resumed.prompt =~ "ORIGINAL"
      assert resumed.prompt =~ "reviewer wrote no verdict"
    end
  end

  describe "resume_opts/2 (base_ref threading)" do
    test "branches the resumed run off the retained failed branch and scrubs the key" do
      opts = Dispatch.resume_opts(item("p"), "run-old-123")

      assert Keyword.get(opts, :base_ref) == "harness/run-old-123"
      assert Keyword.fetch!(opts, :env) == %{"ANTHROPIC_API_KEY" => false}
    end
  end

  describe "rereview/1 — review-only failed-run salvage" do
    test "starts from the retained branch and skips the implementer phase entirely" do
      old_run_id = "run-rereview-old-#{System.unique_integer([:positive])}"
      repo = GitFixture.init_repo()
      default = repo |> GitFixture.git!(["rev-parse", "--abbrev-ref", "HEAD"]) |> String.trim()

      GitFixture.git!(repo, ["checkout", "-b", "harness/#{old_run_id}"])
      File.write!(Path.join(repo, "prior_work.txt"), "already implemented\n")
      GitFixture.git!(repo, ["add", "."])
      GitFixture.git!(repo, ["commit", "-m", "prior attempt"])
      GitFixture.git!(repo, ["checkout", default])

      project =
        ProjectFixture.from_repo(repo,
          name: "rereview-#{System.unique_integer([:positive])}",
          roadmap_path: Path.expand("../fixtures/sample_roadmap", __DIR__),
          reviewer: RereviewCountingAdapter
        )

      :ok = ProjectRegistry.register(project)
      on_exit(fn -> ProjectRegistry.unregister(project.name) end)
      Application.put_env(:harness, :rereview_counting_owner, self())
      on_exit(fn -> Application.delete_env(:harness, :rereview_counting_owner) end)

      :ok =
        ResultStore.record_run(%LogRecord{
          batch_id: "b",
          run_id: old_run_id,
          task_id: "1",
          project_name: project.name,
          adapter: RereviewCountingAdapter,
          state: :failed,
          reason: {:review_stuck, "reviewer wrote no verdict"},
          duration_ms: 1,
          agent: :claude,
          agent_diff_size: 1,
          token_usage: %TokenUsage{input: 100, output: 50, total: 150}
        })

      assert {:ok, %{run_id: new_run_id, rereviewed_from: ^old_run_id}} =
               Dispatch.rereview(old_run_id)

      assert_receive {:rereview_adapter_invoked, "1-review"}, 10_000
      refute_receive {:rereview_adapter_invoked, "1"}, 200

      new_record = wait_for_record(new_run_id)
      assert new_record.state == :done
      assert new_record.reason == :approved
      assert new_record.verdict == :approve
      assert new_record.token_usage == TokenUsage.empty()
      assert new_record.composed_inputs == []
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

    test "the run recovery tools (hold/steer/resume) are on the MCP surface as run_id-string tools" do
      tools = Harness.Manifest.mcp_tools()

      for name <- ~w(dispatch-hold dispatch-steer dispatch-resume) do
        tool = Enum.find(tools, &(&1.name == name))
        assert tool, "#{name} should be on the MCP tool surface"
        assert Map.has_key?(tool.inputSchema.properties, :run_id)
        # run_id is the only undefaulted scalar; steer also requires text.
        assert "run_id" in tool.inputSchema.required
      end

      steer = Enum.find(tools, &(&1.name == "dispatch-steer"))
      assert Map.has_key?(steer.inputSchema.properties, :text)
      assert Enum.sort(steer.inputSchema.required) == ["run_id", "text"]

      hold = Enum.find(tools, &(&1.name == "dispatch-hold"))
      assert Map.has_key?(hold.inputSchema.properties, :interrupt)
      # interrupt defaults to false, so only run_id is required.
      assert hold.inputSchema.required == ["run_id"]
    end

    test "the chat tool registry resolves the run recovery tools to Harness.Dispatch" do
      registry = Tools.build()

      assert %{module: Dispatch, function: :hold} = registry["dispatch-hold"]
      assert %{module: Dispatch, function: :steer} = registry["dispatch-steer"]
      assert %{module: Dispatch, function: :resume} = registry["dispatch-resume"]
    end

    test "the recovery tools (resume_failed/rereview/reland) are on the MCP surface as run_id-string tools" do
      tools = Harness.Manifest.mcp_tools()

      for name <- ~w(dispatch-resume_failed dispatch-rereview dispatch-reland) do
        tool = Enum.find(tools, &(&1.name == name))
        assert tool, "#{name} should be on the MCP tool surface"
        assert Map.has_key?(tool.inputSchema.properties, :run_id)
        assert "run_id" in tool.inputSchema.required
      end

      # resume_failed's escalate defaults to false, so run_id is the only required scalar.
      resume_failed = Enum.find(tools, &(&1.name == "dispatch-resume_failed"))
      assert Map.has_key?(resume_failed.inputSchema.properties, :escalate)
      assert resume_failed.inputSchema.required == ["run_id"]

      rereview = Enum.find(tools, &(&1.name == "dispatch-rereview"))
      assert rereview.inputSchema.required == ["run_id"]
    end

    test "the chat tool registry resolves the recovery tools to Harness.Dispatch" do
      registry = Tools.build()

      assert %{module: Dispatch, function: :resume_failed} = registry["dispatch-resume_failed"]
      assert %{module: Dispatch, function: :rereview} = registry["dispatch-rereview"]
      assert %{module: Dispatch, function: :reland} = registry["dispatch-reland"]
    end

    test "dispatch-register_project is exposed as a flat, JSON-passable tool" do
      tool = Enum.find(Harness.Manifest.mcp_tools(), &(&1.name == "dispatch-register_project"))
      assert tool, "dispatch-register_project should be on the MCP tool surface"

      props = tool.inputSchema.properties
      assert Map.has_key?(props, :name)
      assert Map.has_key?(props, :source_type)
      assert Map.has_key?(props, :source_location)
      assert Map.has_key?(props, :roadmap_path)
      assert Map.has_key?(props, :check_command)
      assert Map.has_key?(props, :concurrency_cap)

      # check_command and concurrency_cap default; the other four are required.
      assert Enum.sort(tool.inputSchema.required) ==
               ["name", "roadmap_path", "source_location", "source_type"]

      assert %{module: Dispatch, function: :register_project} =
               Tools.build()["dispatch-register_project"]
    end

    test "the struct-arg project_registry-register is NOT on the JSON surface" do
      names = Enum.map(Harness.Manifest.mcp_tools(), & &1.name)

      # register/1 takes a %Project{} struct (:exchange_data) a JSON caller
      # cannot construct — JSON orchestrators use dispatch-register_project.
      refute "project_registry-register" in names
      # The non-struct registry reads stay on the surface.
      assert "project_registry-list" in names
      assert "project_registry-lookup" in names
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

  defp item(prompt) do
    %Item{id: "1", title: "t", prompt: prompt, agent: :claude}
  end

  defp log_record(fields) do
    %LogRecord{
      batch_id: "b",
      run_id: Keyword.get(fields, :run_id, "run-x"),
      task_id: Keyword.get(fields, :task_id, "1"),
      adapter: Claude,
      state: Keyword.get(fields, :state, :failed),
      reason: Keyword.get(fields, :reason, {:review_rejected, "r"}),
      duration_ms: 1,
      agent: Keyword.get(fields, :agent, :claude),
      review_report: Keyword.get(fields, :review_report)
    }
  end

  defp approved_result(run_id) do
    %Result{
      run_id: run_id,
      task_id: "25",
      state: :done,
      reason: :approved,
      review: %Review{verdict: :approve, report: "looks good", ratings: %{"code_quality" => 8}},
      worktree_path: "/tmp/wt/#{run_id}",
      agent_diff_size: 12,
      reviewer_diff_size: 0
    }
  end

  defp rejected_result(run_id) do
    %Result{
      run_id: run_id,
      task_id: "25",
      state: :failed,
      reason: {:review_rejected, "nothing salvageable"},
      review: %Review{verdict: :reject, report: "nothing salvageable", ratings: %{"code_quality" => 2}},
      worktree_path: "/tmp/wt/#{run_id}",
      agent_diff_size: 5,
      reviewer_diff_size: 30
    }
  end

  defp wait_for_record(run_id, attempts \\ 100)

  defp wait_for_record(run_id, attempts) when attempts > 0 do
    case ResultStore.list_run_records(run_id: run_id) do
      {:ok, [%LogRecord{} = record | _]} ->
        record

      {:ok, []} ->
        Process.sleep(50)
        wait_for_record(run_id, attempts - 1)

      {:error, reason} ->
        flunk("failed to load run record #{run_id}: #{inspect(reason)}")
    end
  end

  defp wait_for_record(run_id, 0), do: flunk("timed out waiting for run record #{run_id}")

  defp score(agent, domain, composite_score) do
    %CapabilityScore{
      agent: agent,
      domain: domain,
      corpus_version: "test-v1",
      scored_at: ~U[2026-05-30 00:00:00Z],
      run_count: 1,
      success_rate: composite_score / 1_000,
      cost_to_green: 100.0,
      mean_reviewer_diff_size: 0.0,
      composite_score: composite_score,
      raw_metrics: []
    }
  end
end
