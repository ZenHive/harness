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

  describe "collision_pairs output order (accumulator refactor regression)" do
    # The recursive ++ form was replaced with an explicit accumulator +
    # Enum.reverse/2. Collision component discovery (union-find) and shared-file
    # deduplication are order-independent (MapSet ops + Enum.uniq), so the pair
    # list order does not affect observable plan/1 output. This test asserts that
    # plan/1 is stable across a 4-task graph where every pair collides, confirming
    # the accumulator rewrite produces identical collision groupings to the prior form.
    test "collision summary is identical for a fully-connected 4-task collision graph" do
      tasks = [
        task("a", files_to_modify: ["lib/x.ex"]),
        task("b", touches: ["lib/x.ex"]),
        task("c", files_to_modify: ["lib/x.ex"]),
        task("d", touches: ["lib/x.ex"])
      ]

      %WriteSetPlan{waves: waves, collisions: collisions} = WriteSetPlan.plan(tasks)

      # All four tasks collide on the same file — they serialize into 4 waves.
      assert match?([_, _, _, _], waves)
      assert Enum.map(waves, fn [t] -> t["id"] end) == ["a", "b", "c", "d"]

      # One merged collision component covering all four task ids in input order.
      assert [%{task_ids: task_ids, shared_files: ["lib/x.ex"]}] = collisions
      assert task_ids == ["a", "b", "c", "d"]
    end
  end

  defp task(id, fields) do
    fields
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.put("id", id)
  end
end
