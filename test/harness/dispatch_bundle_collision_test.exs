defmodule Harness.DispatchBundleCollisionTest do
  use ExUnit.Case, async: false

  alias Harness.Dispatch
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.Roadmap.Item

  setup do
    env = %{
      agent_model: Application.get_env(:harness, :agent_model),
      oban_insert: Application.get_env(:harness, :oban_insert),
      roadmap_ingest: Application.get_env(:harness, :roadmap_ingest),
      roadmap_next_bundle: Application.get_env(:harness, :roadmap_next_bundle)
    }

    ProjectRegistry.reset()

    on_exit(fn ->
      ProjectRegistry.reset()
      restore_env(:agent_model, env.agent_model)
      restore_env(:oban_insert, env.oban_insert)
      restore_env(:roadmap_ingest, env.roadmap_ingest)
      restore_env(:roadmap_next_bundle, env.roadmap_next_bundle)
    end)

    :ok
  end

  test "dispatch-bundle enqueues only the first wave when bundle task write-sets collide" do
    parent = self()
    project_name = "collision-#{System.unique_integer([:positive])}"
    project = ProjectFixture.from_repo("/tmp/harness-dispatch", name: project_name)

    :ok = ProjectRegistry.register(project)

    Application.put_env(:harness, :roadmap_next_bundle, fn ^project_name ->
      {:ok,
       %{
         bundle: %{"name" => "dispatch-economy"},
         tasks: [
           task("2", files_to_modify: ["src/x"]),
           task("3", touches: ["src/x"]),
           task("19", files_to_modify: ["src/x"])
         ]
       }}
    end)

    Application.put_env(:harness, :roadmap_ingest, fn {:id, id}, opts ->
      {:ok, %Item{id: id, title: "Task #{id}", prompt: "do #{id}", agent: Keyword.fetch!(opts, :agent)}}
    end)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      job = Ecto.Changeset.apply_action!(changeset, :insert)
      send(parent, {:inserted, job.args})
      {:ok, %{job | id: System.unique_integer([:positive])}}
    end)

    assert {:ok,
            %{
              task_ids: ["2"],
              dispatched: 1,
              serialized: %{
                waves: [["2"], ["3"], ["19"]],
                collisions: [%{task_ids: ["2", "3", "19"], shared_files: ["src/x"]}]
              }
            }} = Dispatch.bundle(project_name, "codex", false)

    assert_received {:inserted, %{item_id: "2"}}
    refute_received {:inserted, %{item_id: "3"}}
    refute_received {:inserted, %{item_id: "19"}}
  end

  test "dispatch-bundle routes each assigned task to its own adapter" do
    parent = self()
    project_name = "mixed-roster-#{System.unique_integer([:positive])}"
    project = ProjectFixture.from_repo("/tmp/harness-dispatch", name: project_name)

    :ok = ProjectRegistry.register(project)

    tasks = [
      task("27", assignee: "codex", model: "gpt-5.5"),
      task("28", assignee: "cursor", model: "composer-2.5"),
      task("29", assignee: "grok", model: "grok-composer-2.5-fast")
    ]

    Application.put_env(:harness, :roadmap_next_bundle, fn ^project_name ->
      {:ok, %{bundle: %{"name" => "dispatch-economy"}, tasks: tasks}}
    end)

    Application.put_env(:harness, :roadmap_ingest, fn {:id, id}, opts ->
      source = Enum.find(tasks, &(to_string(&1["id"]) == id))
      agent = Keyword.fetch!(opts, :agent)
      send(parent, {:ingested, id, agent})

      {:ok,
       %Item{
         id: id,
         title: "Task #{id}",
         prompt: "do #{id}",
         agent: agent,
         assignee: agent(source["assignee"]),
         model: source["model"]
       }}
    end)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      job = Ecto.Changeset.apply_action!(changeset, :insert)
      send(parent, {:inserted, job.args})
      {:ok, %{job | id: System.unique_integer([:positive])}}
    end)

    assert {:ok, %{task_ids: ["27", "28", "29"], dispatched: 3}} =
             Dispatch.bundle(project_name, "claude", false)

    assert_received {:ingested, "27", :codex}
    assert_received {:ingested, "28", :cursor}
    assert_received {:ingested, "29", :grok}

    assert_received {:inserted,
                     %{
                       item_id: "27",
                       adapter_module: "Elixir.Harness.AgentAdapter.Codex",
                       requested_model: "gpt-5.5"
                     }}

    assert_received {:inserted,
                     %{
                       item_id: "28",
                       adapter_module: "Elixir.Harness.AgentAdapter.Cursor",
                       requested_model: "composer-2.5"
                     }}

    assert_received {:inserted,
                     %{
                       item_id: "29",
                       adapter_module: "Elixir.Harness.AgentAdapter.Grok",
                       requested_model: "grok-composer-2.5-fast"
                     }}
  end

  test "dispatch-bundle excludes tasks that depend on another pending bundle task" do
    parent = self()
    project_name = "bundle-deps-#{System.unique_integer([:positive])}"
    project = ProjectFixture.from_repo("/tmp/harness-dispatch", name: project_name)

    :ok = ProjectRegistry.register(project)

    Application.put_env(:harness, :roadmap_next_bundle, fn ^project_name ->
      {:ok,
       %{
         bundle: %{"name" => "dispatch-economy"},
         tasks: [
           task("28"),
           task("33", depends_on: ["28"])
         ]
       }}
    end)

    Application.put_env(:harness, :roadmap_ingest, fn {:id, id}, opts ->
      {:ok, %Item{id: id, title: "Task #{id}", prompt: "do #{id}", agent: Keyword.fetch!(opts, :agent)}}
    end)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      job = Ecto.Changeset.apply_action!(changeset, :insert)
      send(parent, {:inserted, job.args})
      {:ok, %{job | id: System.unique_integer([:positive])}}
    end)

    assert {:ok,
            %{
              task_ids: ["28"],
              dispatched: 1,
              serialized: %{waves: [["28"]]}
            }} = Dispatch.bundle(project_name, "codex", false)

    assert_received {:inserted, %{item_id: "28"}}
    refute_received {:inserted, %{item_id: "33"}}
  end

  test "dispatch-bundle persists nil when a foreign pinned model has no default fallback" do
    parent = self()
    project_name = "bundle-foreign-model-#{System.unique_integer([:positive])}"
    project = ProjectFixture.from_repo("/tmp/harness-dispatch", name: project_name)

    :ok = ProjectRegistry.register(project)
    Application.put_env(:harness, :agent_model, [])

    tasks = [
      task("31", assignee: "codex", model: "claude-opus-4-8")
    ]

    Application.put_env(:harness, :roadmap_next_bundle, fn ^project_name ->
      {:ok, %{bundle: %{"name" => "dispatch-economy"}, tasks: tasks}}
    end)

    Application.put_env(:harness, :roadmap_ingest, fn {:id, id}, opts ->
      source = Enum.find(tasks, &(to_string(&1["id"]) == id))

      {:ok,
       %Item{
         id: id,
         title: "Task #{id}",
         prompt: "do #{id}",
         agent: Keyword.fetch!(opts, :agent),
         assignee: agent(source["assignee"]),
         model: source["model"]
       }}
    end)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      job = Ecto.Changeset.apply_action!(changeset, :insert)
      send(parent, {:inserted, job.args})
      {:ok, %{job | id: System.unique_integer([:positive])}}
    end)

    assert {:ok, %{task_ids: ["31"], dispatched: 1}} =
             Dispatch.bundle(project_name, "claude", false)

    assert_received {:inserted,
                     %{
                       item_id: "31",
                       adapter_module: "Elixir.Harness.AgentAdapter.Codex",
                       requested_model: nil
                     }}
  end

  defp task(id, fields \\ []) do
    fields
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.put("id", id)
  end

  defp agent(nil), do: nil
  defp agent(name) when is_binary(name), do: String.to_existing_atom(name)

  defp restore_env(key, nil), do: Application.delete_env(:harness, key)
  defp restore_env(key, value), do: Application.put_env(:harness, key, value)
end
