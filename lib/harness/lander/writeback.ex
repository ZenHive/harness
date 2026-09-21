defmodule Harness.Lander.Writeback do
  @moduledoc "Durable roadmap completion progress and delivery provenance for landing retries."

  alias Harness.ResultStore
  alias Harness.Run.LogRecord

  @doc "Captures every member identity and reviewer before completing roadmap tasks."
  @spec prepare(map()) :: {:ok, map()} | {:error, term()}
  def prepare(request) do
    case ResultStore.fetch_run_record(request.run_id) do
      {:ok, %LogRecord{roadmap_writeback: %{"task_ids" => ids} = progress}}
      when is_list(ids) and ids != [] ->
        {:ok, Map.put_new(progress, "completed_task_ids", [])}

      {:ok, record} ->
        request
        |> merge_members(record)
        |> save()

      {:error, :not_found} ->
        unconfigured_or_missing(request)

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Completes remaining members, recording progress only after each durable write."
  @spec complete(map(), (String.t() -> :ok | {:error, term()})) :: :ok | {:error, term()}
  def complete(request, write_task) do
    with {:ok, progress} <- prepare(request) do
      progress
      |> Map.get("task_ids", [])
      |> Enum.reduce_while({:ok, progress}, &complete_member(&1, &2, request.run_id, write_task))
      |> finish(request.run_id)
    end
  end

  @spec complete_member(String.t(), {:ok, map()}, String.t(), (String.t() -> :ok | {:error, term()})) ::
          {:cont, {:ok, map()}} | {:halt, {:error, term()}}
  defp complete_member(id, {:ok, current}, run_id, write_task) do
    if id in List.wrap(current["completed_task_ids"]) do
      {:cont, {:ok, current}}
    else
      persist_member(id, current, run_id, write_task)
    end
  end

  @spec persist_member(String.t(), map(), String.t(), (String.t() -> :ok | {:error, term()})) ::
          {:cont, {:ok, map()}} | {:halt, {:error, term()}}
  defp persist_member(id, current, run_id, write_task) do
    with :ok <- write_task.(id),
         next = mark_completed(current, id),
         :ok <- ResultStore.put_roadmap_writeback(run_id, next) do
      {:cont, {:ok, next}}
    else
      {:error, reason} -> {:halt, {:error, {:roadmap_writeback_failed, id, reason}}}
    end
  end

  @spec mark_completed(map(), String.t()) :: map()
  defp mark_completed(current, id) do
    Map.update(current, "completed_task_ids", [id], &(List.wrap(&1) ++ [id]))
  end

  @spec finish({:ok, map()} | {:error, term()}, String.t()) :: :ok | {:error, term()}
  defp finish({:ok, progress}, run_id) do
    ResultStore.put_roadmap_writeback(run_id, Map.put(progress, "status", "complete"))
  end

  defp finish({:error, _reason} = error, _run_id), do: error

  @spec merge_members(map(), LogRecord.t()) :: map()
  defp merge_members(request, record) do
    Map.update(request, :task_ids, List.wrap(record.task_ids), fn ids ->
      Enum.uniq(List.wrap(record.task_ids) ++ List.wrap(ids))
    end)
  end

  @spec unconfigured_or_missing(map()) :: {:ok, map()} | {:error, :not_found}
  defp unconfigured_or_missing(request) do
    if ResultStore.configured() in [false, nil], do: {:ok, progress(request)}, else: {:error, :not_found}
  end

  @spec save(map()) :: {:ok, map()} | {:error, term()}
  defp save(request) do
    progress = progress(request)

    with :ok <- ResultStore.put_roadmap_writeback(request.run_id, progress), do: {:ok, progress}
  end

  @spec progress(map()) :: map()
  defp progress(request) do
    %{
      "status" => "pending",
      "task_ids" => Enum.uniq([request.task_id | List.wrap(request[:task_ids])]),
      "task_fingerprint" => request[:task_fingerprint],
      "task_fingerprints" => request[:task_fingerprints] || %{},
      "agent" => name(request[:agent]),
      "reviewer" => name(request[:reviewer]),
      "completed_task_ids" => []
    }
  end

  @spec name(atom() | String.t() | nil) :: String.t() | nil
  defp name(nil), do: nil
  defp name(value), do: to_string(value)
end
