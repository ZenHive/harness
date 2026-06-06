defmodule Harness.Cron.OrchestratorTest do
  use ExUnit.Case, async: false

  alias Harness.Cron.Orchestrator
  alias Harness.ProjectFixture

  setup do
    on_exit(fn -> Application.delete_env(:harness, :cron_orchestrator) end)
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
      # Opus-last policy is stated explicitly.
      assert prompt =~ "Claude"
    end
  end

  describe "plan/2 — injectable for tests, real-invoke otherwise" do
    test "delegates to the configured fun when set" do
      project = ProjectFixture.from_repo("/tmp/harness-orch-inject", name: "orch-inject")
      parent = self()

      Application.put_env(:harness, :cron_orchestrator, fn p, ready ->
        send(parent, {:planned, p.name, length(ready)})
        {:ok, %Orchestrator{dispatch: [%{task_id: "1", adapter: "codex"}], skip: []}}
      end)

      assert {:ok, %Orchestrator{dispatch: [%{task_id: "1", adapter: "codex"}]}} =
               Orchestrator.plan(project, [%{"id" => "1"}, %{"id" => "2"}])

      assert_received {:planned, "orch-inject", 2}
    end
  end

  @spec write_plan(String.t(), String.t()) :: :ok
  defp write_plan(dir, body) do
    artifact = Path.join(dir, ".harness/cron-plan.json")
    File.mkdir_p!(Path.dirname(artifact))
    File.write!(artifact, body)
  end
end
