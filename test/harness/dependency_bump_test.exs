defmodule Harness.DependencyBumpTest do
  use ExUnit.Case, async: false

  alias Harness.AgentAdapter.Codex
  alias Harness.DependencyBump
  alias Harness.DependencyBump.TaskSpec
  alias Harness.DepFreshness.Row
  alias Harness.DepFreshness.Snapshot
  alias Harness.DepFreshnessStore
  alias Harness.DepFreshnessStore.Memory, as: Store
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.Roadmap.Item

  setup do
    prev_store = Application.get_env(:harness, :dep_freshness_store)
    prev_creator = Application.get_env(:harness, :dependency_bump_task_creator)
    prev_enqueuer = Application.get_env(:harness, :dependency_bump_enqueuer)
    prev_ingest = Application.get_env(:harness, :roadmap_ingest)

    Application.put_env(:harness, :dep_freshness_store, {Store, scope: :dependency_bump_test})

    for project <- ProjectRegistry.list(), do: ProjectRegistry.unregister(project.name)

    on_exit(fn ->
      restore_env(:dep_freshness_store, prev_store)
      restore_env(:dependency_bump_task_creator, prev_creator)
      restore_env(:dependency_bump_enqueuer, prev_enqueuer)
      restore_env(:roadmap_ingest, prev_ingest)

      for project <- ProjectRegistry.list(), do: ProjectRegistry.unregister(project.name)
    end)

    :ok
  end

  test "build_task_specs batches minor and patch bumps and splits major bumps per ecosystem" do
    project = ProjectFixture.from_repo("/tmp/dependency-bump-specs", languages: [:elixir, :rust])
    snapshot = Snapshot.build(project.name, "elixir,rust", rows())

    assert {:ok, specs} = DependencyBump.build_task_specs(project, snapshot)

    assert Enum.map(specs, &{&1.language, &1.kind, Enum.map(&1.rows, fn row -> row.name end)}) == [
             {:elixir, :minor_patch, ["req", "plug"]},
             {:elixir, :major, ["phoenix"]},
             {:rust, :minor_patch, ["serde"]}
           ]

    elixir_minor = Enum.find(specs, &(&1.language == :elixir and &1.kind == :minor_patch))
    assert elixir_minor.body =~ "| req | 0.5.0 | 0.5.1 | yes |"
    assert elixir_minor.body =~ "| plug | 1.14.0 | 1.15.0 | no |"
    assert elixir_minor.body =~ "widen the constraint in `mix.exs` to idiomatic `~> x.y`"
    assert elixir_minor.body =~ "mix deps.update req, plug"
    assert elixir_minor.body =~ "mix test.json --include integration"
    assert elixir_minor.check_command == "mix test.json --quiet --all --include integration"
  end

  test "dispatch creates rmap tasks from freshness facts and enqueues reviewer-gated runs" do
    owner = self()
    project = ProjectFixture.from_repo("/tmp/dependency-bump-dispatch", name: "dependency-bump-dispatch")
    :ok = ProjectRegistry.register(project)

    :ok =
      DepFreshnessStore.record_snapshot(
        Snapshot.build(project.name, "elixir", Enum.take(rows(), 2)),
        DepFreshnessStore.configured()
      )

    Application.put_env(:harness, :dependency_bump_task_creator, fn created_project, specs, adapter, model ->
      send(owner, {:created, created_project.name, specs, adapter, model})
      {:ok, ["501"]}
    end)

    Application.put_env(:harness, :roadmap_ingest, fn {:id, "501"}, opts ->
      send(owner, {:ingested, opts[:project].name, opts[:agent]})
      {:ok, %Item{id: "501", title: "deps", prompt: "prompt", agent: opts[:agent], model: "gpt-5.5"}}
    end)

    Application.put_env(:harness, :dependency_bump_enqueuer, fn enqueued_project, item, adapter, opts ->
      send(owner, {:enqueued, enqueued_project.name, item.id, adapter, opts})
      {:ok, "run-501", %Oban.Job{id: 501}}
    end)

    assert {:ok, %{tasks: [task]}} = DependencyBump.dispatch(project.name, "codex", "gpt-5.5", true)
    assert task.run_id == "run-501"
    assert task.task_id == "501"
    assert task.dependencies == ["req", "plug"]

    assert_received {:created, "dependency-bump-dispatch", [%TaskSpec{} = spec], "codex", "gpt-5.5"}
    assert spec.body =~ "Ground-truth dependency freshness facts"
    assert spec.body =~ "| req | 0.5.0 | 0.5.1 | yes |"

    assert_received {:ingested, "dependency-bump-dispatch", :codex}

    assert_received {:enqueued, "dependency-bump-dispatch", "501", Codex, opts}
    assert Keyword.fetch!(opts, :check_command) == "mix test.json --quiet --all --include integration"
    assert Keyword.fetch!(opts, :env) == %{"ANTHROPIC_API_KEY" => false}
    assert Keyword.fetch!(opts, :requested_model) == "gpt-5.5"
  end

  @spec rows() :: [Row.t()]
  defp rows do
    [
      %Row{
        name: "req",
        current_version: "0.5.0",
        latest_version: "0.5.1",
        constraint_allowed: true,
        language: :elixir
      },
      %Row{
        name: "plug",
        current_version: "1.14.0",
        latest_version: "1.15.0",
        constraint_allowed: false,
        language: :elixir
      },
      %Row{
        name: "phoenix",
        current_version: "1.7.0",
        latest_version: "2.0.0",
        constraint_allowed: false,
        language: :elixir
      },
      %Row{
        name: "serde",
        current_version: "1.0.0",
        latest_version: "1.0.1",
        constraint_allowed: true,
        language: :rust
      }
    ]
  end

  @spec restore_env(atom(), term()) :: :ok
  defp restore_env(key, nil), do: Application.delete_env(:harness, key)
  defp restore_env(key, value), do: Application.put_env(:harness, key, value)
end
