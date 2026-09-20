defmodule Harness.Insights.Consultation do
  @moduledoc "AI-directed bounded reads of immutable evidence and prior finding pages."
  alias Harness.Insights.CodexWitness
  alias Harness.Insights.Evidence
  alias Harness.Insights.Store
  alias Harness.Insights.Witness

  @page 20
  @reads 32

  @doc "Completes retrieval before returning a publishable observation."
  @spec run(map(), map()) :: {:ok, map(), [map()], [map()]} | {:error, term()}
  def run(%{changed: 0} = batch, _config), do: {:ok, %{"findings" => []}, batch.sources, []}

  def run(batch, config) do
    previous = Store.list("finding", 0, @page)

    context = %{
      "sources" => batch.sources,
      "previous_findings" => previous,
      "finding_next_offset" => next_offset(previous, 0),
      "partial_evidence" => batch.partial,
      "history_pending" => batch.pending,
      "observer" => Map.take(config, ["agent", "model"])
    }

    timeout = Application.get_env(:harness, :insights_timeout_ms, 180_000)
    config = Map.put(config, "deadline", System.monotonic_time(:millisecond) + timeout)
    consult(context, batch, config, batch.sources, previous, @reads)
  end

  @spec consult(map(), map(), map(), [map()], [map()], non_neg_integer()) ::
          {:ok, map(), [map()], [map()]} | {:error, term()}
  defp consult(context, batch, config, sources, previous, remaining) do
    default = if config["agent"] == "codex", do: CodexWitness, else: Witness
    witness = Application.get_env(:harness, :insights_witness, default)

    case invoke(witness, context, config) do
      {:ok, %{"read" => request}} when is_map(request) and remaining > 0 ->
        with {:ok, update, added_sources, added_findings} <- read(request, batch) do
          sources = Enum.uniq_by(sources ++ added_sources, & &1["source_id"])
          previous = Enum.uniq_by(previous ++ added_findings, & &1["id"])
          context = context |> Map.merge(update) |> Map.put("sources", sources) |> Map.put("previous_findings", previous)
          consult(context, batch, config, sources, previous, remaining - 1)
        end

      {:ok, %{"read" => request}} when is_map(request) ->
        {:error, :retrieval_limit_reached}

      {:ok, response} ->
        {:ok, response, sources, previous}

      {:error, _} = error ->
        error
    end
  end

  @spec invoke(module(), map(), map()) :: {:ok, map()} | {:error, term()}
  defp invoke(witness, context, config) do
    task =
      Task.async(fn ->
        try do
          witness.observe(context, config["model"])
        rescue
          error -> {:error, {:witness_exception, Exception.message(error)}}
        catch
          kind, reason -> {:error, {kind, reason}}
        end
      end)

    remaining = max(config["deadline"] - System.monotonic_time(:millisecond), 0)

    case Task.yield(task, remaining) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :observation_timeout}
    end
  end

  @spec read(map(), map()) :: {:ok, map(), [map()], [map()]} | {:error, term()}
  defp read(%{"kind" => "findings", "offset" => offset}, _batch) when is_integer(offset) and offset >= 0 do
    page = Store.list("finding", offset, @page)
    {:ok, %{"previous_findings" => page, "finding_next_offset" => next_offset(page, offset)}, [], page}
  end

  defp read(%{"kind" => "source", "source_id" => id, "offset" => offset}, batch) do
    with {:ok, source} <- Evidence.read(batch, id, offset) do
      {:ok, %{"read_result" => source}, [source], []}
    end
  end

  defp read(_, _), do: {:error, :invalid_read_request}

  @spec next_offset([map()], non_neg_integer()) :: non_neg_integer() | nil
  defp next_offset(page, offset), do: if(length(page) == @page, do: offset + @page)
end
