defmodule Harness.ToolingBaseline.DispatchTest do
  use ExUnit.Case, async: false

  alias Harness.AgentAdapter.Codex
  alias Harness.DepFreshness.Snapshot, as: FreshnessSnapshot
  alias Harness.DepFreshnessStore
  alias Harness.DepFreshnessStore.Memory, as: Store
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.Roadmap.Item, as: RoadmapItem
  alias Harness.ToolingBaseline.Dispatch
  alias Harness.ToolingBaseline.Item
  alias Harness.ToolingBaseline.Snapshot
  alias Harness.ToolingBaseline.TaskSpec

  setup do
    prev_store = Application.get_env(:harness, :dep_freshness_store)
    prev_creator = Application.get_env(:harness, :tooling_baseline_task_creator)
    prev_enqueuer = Application.get_env(:harness, :tooling_baseline_enqueuer)
    prev_ingest = Application.get_env(:harness, :roadmap_ingest)

    Application.put_env(:harness, :dep_freshness_store, {Store, scope: :tooling_baseline_dispatch_test})

    for project <- ProjectRegistry.list(), do: ProjectRegistry.unregister(project.name)

    on_exit(fn ->
      restore_env(:dep_freshness_store, prev_store)
      restore_env(:tooling_baseline_task_creator, prev_creator)
      restore_env(:tooling_baseline_enqueuer, prev_enqueuer)
      restore_env(:roadmap_ingest, prev_ingest)

      for project <- ProjectRegistry.list(), do: ProjectRegistry.unregister(project.name)
    end)

    :ok
  end

  test "dispatch creates a baseline task from conformance facts and enqueues the reviewer-gated run" do
    owner = self()

    project =
      ProjectFixture.from_repo("/tmp/tooling-baseline-dispatch",
        name: "tooling-baseline-dispatch",
        languages: [:elixir, :rust]
      )

    :ok = ProjectRegistry.register(project)

    :ok =
      DepFreshnessStore.record_snapshot(
        FreshnessSnapshot.build(project.name, "elixir,rust", [], conformance: conformance_snapshot()),
        DepFreshnessStore.configured()
      )

    Application.put_env(:harness, :tooling_baseline_task_creator, fn created_project, specs, adapter, model ->
      send(owner, {:created, created_project.name, specs, adapter, model})
      {:ok, ["801"]}
    end)

    Application.put_env(:harness, :roadmap_ingest, fn {:id, "801"}, opts ->
      send(owner, {:ingested, opts[:project].name, opts[:agent]})
      {:ok, %RoadmapItem{id: "801", title: "baseline", prompt: "prompt", agent: opts[:agent], model: "gpt-5.5"}}
    end)

    Application.put_env(:harness, :tooling_baseline_enqueuer, fn enqueued_project, item, adapter, opts ->
      send(owner, {:enqueued, enqueued_project.name, item.id, adapter, opts})
      {:ok, "run-801", %Oban.Job{id: 801}}
    end)

    assert {:ok, %{tasks: [task], skipped_languages: [%{language: :rust}]}} =
             Dispatch.dispatch(project.name, "codex", "gpt-5.5", true)

    assert task.run_id == "run-801"
    assert task.task_id == "801"
    assert task.missing == ["dep:credo", "alias:ci", "config:.credo.exs"]
    assert task.skipped_languages == [%{language: :rust, reason: {:unsupported_language, :rust}}]

    assert_received {:created, "tooling-baseline-dispatch", [%TaskSpec{} = spec], "codex", "gpt-5.5"}
    assert spec.body =~ "Ground-truth tooling baseline drift facts"
    assert spec.body =~ "| dep | credo | dep:credo |"
    assert spec.body =~ "| alias | ci | alias:ci |"
    assert spec.body =~ "| config_file | .credo.exs | config:.credo.exs |"
    assert spec.body =~ "mix igniter.install vibe_kit"
    assert spec.body =~ "elixir-setup extras"
    assert spec.body =~ "`ci` and `precommit` Mix aliases"
    assert spec.body =~ "Skipped project languages with no tooling-baseline provider"
    assert spec.body =~ "| rust | {:unsupported_language, :rust} |"
    assert spec.check_command == "mix compile --warnings-as-errors && mix ci"

    assert_received {:ingested, "tooling-baseline-dispatch", :codex}

    assert_received {:enqueued, "tooling-baseline-dispatch", "801", Codex, opts}
    assert Keyword.fetch!(opts, :check_command) == "mix compile --warnings-as-errors && mix ci"
    assert Keyword.fetch!(opts, :env) == %{"ANTHROPIC_API_KEY" => false}
    assert Keyword.fetch!(opts, :requested_model) == "gpt-5.5"
  end

  test "unsupported languages are returned as skipped without creating an Elixir task" do
    owner = self()
    project = ProjectFixture.from_repo("/tmp/tooling-baseline-rust", name: "tooling-baseline-rust", languages: [:rust])
    :ok = ProjectRegistry.register(project)

    :ok =
      DepFreshnessStore.record_snapshot(
        FreshnessSnapshot.build(project.name, "rust", [],
          conformance: Snapshot.build([Item.skipped(:rust, :unsupported)], [])
        ),
        DepFreshnessStore.configured()
      )

    Application.put_env(:harness, :tooling_baseline_task_creator, fn _project, _specs, _adapter, _model ->
      send(owner, :unexpected_task_creation)
      {:ok, []}
    end)

    assert {:ok, %{tasks: [], skipped_languages: [%{language: :rust, reason: {:unsupported_language, :rust}}]}} =
             Dispatch.dispatch(project.name, "codex", nil, true)

    refute_received :unexpected_task_creation
  end

  @spec conformance_snapshot() :: Snapshot.t()
  defp conformance_snapshot do
    Snapshot.build(
      [
        %Item{id: "dep:credo", label: "credo", category: :dep, status: :missing},
        %Item{id: "alias:ci", label: "ci", category: :alias, status: :missing},
        %Item{id: "config:.credo.exs", label: ".credo.exs", category: :config_file, status: :missing},
        %Item{id: "dep:doctor", label: "doctor", category: :dep, status: :present}
      ],
      []
    )
  end

  @spec restore_env(atom(), term()) :: :ok
  defp restore_env(key, nil), do: Application.delete_env(:harness, key)
  defp restore_env(key, value), do: Application.put_env(:harness, key, value)
end
