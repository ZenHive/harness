defmodule Harness.Dispatch.WriteSetPlan do
  @moduledoc """
  Mechanical write-set collision planner for roadmap dispatch waves.

  A task's write-set is the union of its `touches` and `files_to_modify` fields.
  Tasks with intersecting write-sets are placed in separate waves so the next
  task starts only after the previous wave has had a chance to land.
  """

  @type task :: map()
  @type collision :: %{task_ids: [String.t()], shared_files: [String.t()]}
  @type t :: %__MODULE__{
          waves: [[task()]],
          collisions: [collision()]
        }

  defstruct waves: [], collisions: []

  @doc "Plans ready tasks into collision-free dispatch waves."
  @spec plan([task()]) :: t()
  def plan(tasks) when is_list(tasks) do
    %__MODULE__{
      waves: waves(tasks),
      collisions: collisions(tasks)
    }
  end

  @doc false
  @spec write_set(task()) :: MapSet.t(String.t())
  def write_set(task) when is_map(task) do
    task
    |> Map.take(["touches", "files_to_modify"])
    |> Map.values()
    |> Enum.flat_map(&strings/1)
    |> MapSet.new()
  end

  @doc false
  @spec wave_ids([[task()]]) :: [[String.t()]]
  def wave_ids(waves) when is_list(waves) do
    Enum.map(waves, fn wave -> Enum.map(wave, &task_id/1) end)
  end

  @spec waves([task()]) :: [[task()]]
  defp waves(tasks) do
    tasks
    |> Enum.reduce([], &place_task/2)
    |> Enum.map(&Enum.reverse/1)
  end

  @spec place_task(task(), [[task()]]) :: [[task()]]
  defp place_task(task, []), do: [[task]]

  defp place_task(task, [wave | rest]) do
    if disjoint_from_wave?(task, wave),
      do: [[task | wave] | rest],
      else: [wave | place_task(task, rest)]
  end

  @spec disjoint_from_wave?(task(), [task()]) :: boolean()
  defp disjoint_from_wave?(task, wave) do
    write_set = write_set(task)
    Enum.all?(wave, &MapSet.disjoint?(write_set, write_set(&1)))
  end

  @spec collisions([task()]) :: [collision()]
  defp collisions(tasks) do
    pairs = collision_pairs(tasks)

    pairs
    |> collision_components()
    |> Enum.map(&collision_summary(&1, pairs, tasks))
  end

  # Accumulator-based rewrite of the original recursive ++ form. The prior version
  # prepended each head's pairs and then appended the recursive result at every
  # level, making the total list-building work O(n²) in the number of tasks.
  #
  # The new form prepends pairs in reverse order into `acc` at each level, then
  # reverses once at the base case — identical output order, O(n) total list work.
  # Output order is preserved: pairs are enumerated in the same left-to-right,
  # outer-first order as before (verified: collision_components sorts its
  # components and component_shared_files uses MapSet/uniq, so pair order is
  # immaterial to callers, but we preserve it for referential transparency).
  @spec collision_pairs([task()], [map()]) :: [map()]
  defp collision_pairs(tasks, acc \\ [])
  defp collision_pairs([], acc), do: Enum.reverse(acc)

  defp collision_pairs([task | rest], acc) do
    pairs = Enum.flat_map(rest, &collision_pair(task, &1))
    # Enum.reverse(pairs, acc) = Enum.reverse(pairs) ++ acc — no intermediate ++ traversal.
    collision_pairs(rest, Enum.reverse(pairs, acc))
  end

  @spec collision_pair(task(), task()) :: [map()]
  defp collision_pair(left, right) do
    shared_files =
      left
      |> write_set()
      |> MapSet.intersection(write_set(right))
      |> MapSet.to_list()
      |> Enum.sort()

    case shared_files do
      [] -> []
      files -> [%{task_ids: [task_id(left), task_id(right)], shared_files: files}]
    end
  end

  @spec collision_components([map()]) :: [MapSet.t(String.t())]
  defp collision_components(pairs) do
    pairs
    |> Enum.reduce([], &merge_pair/2)
    |> Enum.map(&MapSet.to_list/1)
    |> Enum.sort()
    |> Enum.map(&MapSet.new/1)
  end

  @spec merge_pair(map(), [MapSet.t(String.t())]) :: [MapSet.t(String.t())]
  defp merge_pair(%{task_ids: ids}, components) do
    pair_set = MapSet.new(ids)
    {overlapping, disjoint} = Enum.split_with(components, &(not MapSet.disjoint?(&1, pair_set)))
    [Enum.reduce(overlapping, pair_set, &MapSet.union/2) | disjoint]
  end

  @spec collision_summary(MapSet.t(String.t()), [map()], [task()]) :: collision()
  defp collision_summary(component, pairs, tasks) do
    %{
      task_ids: ordered_component_ids(component, tasks),
      shared_files: component |> component_shared_files(pairs) |> Enum.sort()
    }
  end

  @spec ordered_component_ids(MapSet.t(String.t()), [task()]) :: [String.t()]
  defp ordered_component_ids(component, tasks) do
    tasks
    |> Enum.map(&task_id/1)
    |> Enum.filter(&MapSet.member?(component, &1))
  end

  @spec component_shared_files(MapSet.t(String.t()), [map()]) :: [String.t()]
  defp component_shared_files(component, pairs) do
    pairs
    |> Enum.filter(&pair_in_component?(&1, component))
    |> Enum.flat_map(& &1.shared_files)
    |> Enum.uniq()
  end

  @spec pair_in_component?(map(), MapSet.t(String.t())) :: boolean()
  defp pair_in_component?(%{task_ids: ids}, component) do
    Enum.all?(ids, &MapSet.member?(component, &1))
  end

  @spec strings(term()) :: [String.t()]
  defp strings(values) when is_list(values), do: Enum.filter(values, &is_binary/1)
  defp strings(_values), do: []

  @spec task_id(task()) :: String.t()
  defp task_id(task), do: task |> Map.get("id") |> to_string()
end
