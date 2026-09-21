defmodule Harness.Lander.Writeback do
  @moduledoc "Durable roadmap completion progress and delivery provenance for landing retries."

  alias Harness.ResultStore
  alias Harness.Run.LogRecord

  @doc "Captures every member identity and reviewer before completing roadmap tasks."
  @spec prepare(map()) :: {:ok, map()} | {:error, term()}
  def prepare(request) do
    case ResultStore.fetch_run_record(request.run_id) do
      {:ok, %LogRecord{roadmap_writeback: progress}} when is_map(progress) ->
        {:ok, progress}

      {:ok, record} ->
        request
        |> Map.update(:task_ids, record.task_ids, &Enum.uniq(record.task_ids ++ (&1 || [])))
        |> save()

      {:error, :not_found} ->
        if ResultStore.configured() in [false, nil], do: {:ok, progress(request)}, else: {:error, :not_found}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Completes remaining members, recording progress only after each durable write."
  @spec complete(map(), (String.t() -> :ok | {:error, term()})) :: :ok | {:error, term()}
  def complete(request, write_task) do
    with {:ok, progress} <- prepare(request) do
      progress["task_ids"]
      |> Enum.reduce_while({:ok, progress}, fn id, {:ok, current} ->
        if id in current["completed_task_ids"] do
          {:cont, {:ok, current}}
        else
          with :ok <- write_task.(id),
               next = %{current | "completed_task_ids" => current["completed_task_ids"] ++ [id]},
               :ok <- ResultStore.put_roadmap_writeback(request.run_id, next) do
            {:cont, {:ok, next}}
          else
            {:error, reason} -> {:halt, {:error, {:roadmap_writeback_failed, id, reason}}}
          end
        end
      end)
      |> finish(request.run_id)
    end
  end

  @spec finish({:ok, map()} | {:error, term()}, String.t()) :: :ok | {:error, term()}
  defp finish({:ok, progress}, run_id) do
    ResultStore.put_roadmap_writeback(run_id, Map.put(progress, "status", "complete"))
  end

  defp finish({:error, _reason} = error, _run_id), do: error

  @spec save(map()) :: {:ok, map()} | {:error, term()}
  defp save(request) do
    progress = progress(request)

    with :ok <- ResultStore.put_roadmap_writeback(request.run_id, progress), do: {:ok, progress}
  end

  @spec progress(map()) :: map()
  defp progress(request) do
    %{
      "status" => "pending",
      "task_ids" => Enum.uniq([request.task_id | request[:task_ids] || []]),
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
