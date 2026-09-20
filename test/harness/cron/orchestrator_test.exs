defmodule Harness.Cron.OrchestratorTest do
  # async: false because tests mutate the global :cron_orchestrator application env.
  use ExUnit.Case, async: false

  alias Harness.Cron.Orchestrator
  alias Harness.ProjectFixture
  alias Harness.ResultStore.Memory

  setup do
    previous = Application.get_env(:harness, :result_store)
    Application.put_env(:harness, :result_store, {Memory, scope: make_ref()})

    on_exit(fn ->
      Application.delete_env(:harness, :cron_orchestrator)
      Application.put_env(:harness, :result_store, previous)
    end)

    :ok
  end

  describe "read/1 — the plan artifact is read mechanically" do
    @describetag :tmp_dir

    test "parses a well-formed plan into dispatch + skip entries", %{tmp_dir: dir} do
      write_plan(dir, """
      {
        "dispatch": [
          {"task_id": "234", "adapter": "codex"},
          {"task_id": "227", "adapter": "cursor"}
        ],
        "skip": [
          {"task_id": "236", "disposition": "defer", "reason": "overlaps 234 on lander.ex"}
        ]
      }
      """)

      assert {:ok, plan} = Orchestrator.read(dir)

      assert plan.dispatch == [
               %{task_id: "234", adapter: "codex"},
               %{task_id: "227", adapter: "cursor"}
             ]

      assert plan.skip == [%{task_id: "236", disposition: "defer", reason: "overlaps 234 on lander.ex"}]
    end

    test "preserves the recovery selection and its rationale", %{tmp_dir: dir} do
      write_plan(
        dir,
        ~s({"dispatch":[{"task_id":"435","adapter":"codex","model":"gpt-6-astra","action":"resume","source_run_id":"prior","reason":"Retain useful commits"}]})
      )

      assert {:ok, %Orchestrator{dispatch: [entry]}} = Orchestrator.read(dir)

      assert entry == %{
               task_id: "435",
               adapter: "codex",
               model: "gpt-6-astra",
               action: "resume",
               source_run_id: "prior",
               reason: "Retain useful commits"
             }
    end

    test "tolerates a missing skip list", %{tmp_dir: dir} do
      write_plan(dir, ~s({"dispatch": [{"task_id": "1", "adapter": "codex"}]}))

      assert {:ok, %Orchestrator{dispatch: [%{task_id: "1", adapter: "codex"}], skip: []}} = Orchestrator.read(dir)
    end

    test "drops dispatch entries missing task_id or adapter", %{tmp_dir: dir} do
      write_plan(dir, """
      {"dispatch": [{"task_id": "1", "adapter": "codex"}, {"task_id": "2"}, {"adapter": "cursor"}]}
      """)

      assert {:ok, %Orchestrator{dispatch: [%{task_id: "1", adapter: "codex"}]}} = Orchestrator.read(dir)
    end

    test "a missing artifact is {:error, :missing}", %{tmp_dir: dir} do
      assert {:error, :missing} = Orchestrator.read(dir)
    end

    test "malformed JSON is {:error, {:malformed, _}}", %{tmp_dir: dir} do
      write_plan(dir, "{not json")

      assert {:error, {:malformed, _reason}} = Orchestrator.read(dir)
    end

    test "JSON without a dispatch list is {:error, {:malformed, _}}", %{tmp_dir: dir} do
      write_plan(dir, ~s({"skip": []}))

      assert {:error, {:malformed, _reason}} = Orchestrator.read(dir)
    end
  end

  describe "prompt/1 — the orchestrator gets full context + the hard rules" do
    test "embeds the touch-disjoint rule, the cap, and the ready set as JSON" do
      project = ProjectFixture.from_repo("/tmp/harness-orch-prompt", name: "orch", concurrency_cap: 3)

      ready = [
        %{"id" => "234", "assignee" => "codex", "touches" => ["lib/a.ex"], "scores" => %{"d" => 3}},
        %{"id" => "227", "assignee" => "cursor", "touches" => ["lib/b.ex"]}
      ]

      prompt = Orchestrator.prompt(Orchestrator.context(project, ready))

      assert prompt =~ ".harness/cron-plan.json"
      assert prompt =~ "touches"
      assert prompt =~ "in_flight"
      # The cap is surfaced so the orchestrator sizes the wave under it.
      assert prompt =~ "3"
      # Each candidate task id reaches the orchestrator.
      assert prompt =~ "234"
      assert prompt =~ "227"
      # Routing is bounded by the operator-enabled roster, not a hardcoded agent.
      refute prompt =~ "Opus"
      assert prompt =~ "enabled: true"
      assert prompt =~ ~s("agents")
      assert prompt =~ "action"
      assert prompt =~ "resume"
      assert prompt =~ "rereview"
      assert prompt =~ "fresh"
      assert prompt =~ "Do not apply a fixed retry count"
      assert prompt =~ "disposable non-Git scratch directory"
      assert prompt =~ "are your recovery evidence source"
      assert prompt =~ "means verified empty history"
      assert prompt =~ "no prior branch/origin evidence is required"
      assert prompt =~ "For prior attempts, missing required branch/origin evidence"
      assert prompt =~ "never equivalent to `attempts: []`"
      assert prompt =~ "Recovery of coalesced runs is unsupported"
    end
  end

  describe "plan/2 — injectable for tests, real-invoke otherwise" do
    test "delegates to the configured fun when set" do
      project = ProjectFixture.from_repo("/tmp/harness-orch-inject", name: "orch-inject")
      parent = self()

      Application.put_env(:harness, :cron_orchestrator, fn p, ready ->
        send(parent, {:planned, p.name, ready})
        {:ok, %Orchestrator{dispatch: [%{task_id: "1", adapter: "codex"}], skip: []}}
      end)

      assert {:ok, %Orchestrator{dispatch: [%{task_id: "1", adapter: "codex"}]}} =
               Orchestrator.plan(project, [%{"id" => "1"}, %{"id" => "2"}])

      assert_received {:planned, "orch-inject", [%{"attempts" => []}, %{"attempts" => []}]}
    end

    test "disabled or unavailable history fails before invoking the planner" do
      project = ProjectFixture.from_repo("/tmp/harness-orch-history", name: "orch-history")
      parent = self()

      Application.put_env(:harness, :cron_orchestrator, fn _, _ ->
        send(parent, :planned)
        flunk("Unavailable history must not reach the planner")
      end)

      Application.put_env(:harness, :result_store, false)
      assert {:error, :history_store_disabled} = Orchestrator.plan(project, [%{"id" => "1"}])
      Application.put_env(:harness, :result_store, {Harness.ResultStore.Postgres, []})
      assert {:error, %RuntimeError{}} = Orchestrator.plan(project, [%{"id" => "1"}])
      refute_received :planned
    end
  end

  @tag :tmp_dir
  test "real invocation reads its artifact and cleans scratch on success and failure", %{tmp_dir: dir} do
    old_path = System.get_env("PATH")
    old_config = Application.get_env(:harness, :cron_polling)
    old_model = Application.get_env(:harness, :agent_model)
    System.put_env("PATH", dir <> ":" <> old_path)
    Application.put_env(:harness, :agent_model, codex: "gpt-6-astra")
    Application.put_env(:harness, :cron_polling, orchestrator_adapter: :codex)

    on_exit(fn ->
      System.put_env("PATH", old_path)

      if old_config,
        do: Application.put_env(:harness, :cron_polling, old_config),
        else: Application.delete_env(:harness, :cron_polling)

      if old_model,
        do: Application.put_env(:harness, :agent_model, old_model),
        else: Application.delete_env(:harness, :agent_model)
    end)

    executable = Path.join(dir, "codex")

    File.write!(executable, """
    #!/bin/sh
    mkdir -p .harness
    echo '{"dispatch": [{"task_id":"1","adapter":"codex"}]}' > .harness/cron-plan.json
    """)

    File.chmod!(executable, 0o755)
    project = ProjectFixture.from_repo(dir, name: "orch-invoke")
    assert {:ok, %Orchestrator{dispatch: [%{task_id: "1"}]}} = Orchestrator.plan(project, [%{"id" => "1"}])
    assert Path.wildcard(Path.join(System.tmp_dir!(), "harness-cron-orch-invoke-*")) == []
    File.write!(executable, "#!/bin/sh\nexit 0\n")
    assert {:error, :missing} = Orchestrator.plan(project, [])
    Application.put_env(:harness, :cron_polling, orchestrator_adapter: :unknown)
    assert {:error, {:no_adapter, _}} = Orchestrator.plan(project, [])
  end

  @spec write_plan(String.t(), String.t()) :: :ok
  defp write_plan(dir, body) do
    artifact = Path.join(dir, ".harness/cron-plan.json")
    File.mkdir_p!(Path.dirname(artifact))
    File.write!(artifact, body)
  end
end
