defmodule Harness.Dispatch.WriteSetPlanTest do
  use ExUnit.Case, async: true

  alias Harness.Dispatch.WriteSetPlan

  describe "plan/1" do
    test "serializes a ready set whose write-sets overlap" do
      tasks = [
        task("2", files_to_modify: ["src/x"]),
        task("3", touches: ["src/x"]),
        task("19", files_to_modify: ["src/x"])
      ]

      assert %WriteSetPlan{
               waves: [[first], [second], [third]],
               collisions: [%{task_ids: ["2", "3", "19"], shared_files: ["src/x"]}]
             } = WriteSetPlan.plan(tasks)

      assert first["id"] == "2"
      assert second["id"] == "3"
      assert third["id"] == "19"
    end

    test "fans out tasks with disjoint write-sets in the same wave" do
      tasks = [
        task("2", files_to_modify: ["src/a"]),
        task("3", touches: ["src/b"]),
        task("19", files_to_modify: ["src/c"])
      ]

      assert %WriteSetPlan{waves: [wave], collisions: []} = WriteSetPlan.plan(tasks)
      assert Enum.map(wave, & &1["id"]) == ["2", "3", "19"]
    end
  end

  defp task(id, fields) do
    fields
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.put("id", id)
  end
end
