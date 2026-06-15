defmodule Harness.DispatchBundleCollisionTest do
  use ExUnit.Case, async: false

  alias Harness.Dispatch
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.Roadmap.Item

  setup do
    env = %{
      oban_insert: Application.get_env(:harness, :oban_insert),
      roadmap_ingest: Application.get_env(:harness, :roadmap_ingest),
      roadmap_next_bundle: Application.get_env(:harness, :roadmap_next_bundle)
    }

    ProjectRegistry.reset()

    on_exit(fn ->
      ProjectRegistry.reset()
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

  defp task(id, fields) do
    fields
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.put("id", id)
  end

  defp restore_env(key, nil), do: Application.delete_env(:harness, key)
  defp restore_env(key, value), do: Application.put_env(:harness, key, value)
end
