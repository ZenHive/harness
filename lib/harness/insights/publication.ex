defmodule Harness.Insights.Publication do
  @moduledoc "Validates publication structure and exact citations without interpreting findings."

  @fields ~w(title explanation facts hypothesis improvement assessment contradictions recurrence)

  @doc "Validates references and snapshots cited evidence before publication."
  @spec prepare(map(), [map()], [map()], String.t(), map()) :: {:ok, [tuple()]} | {:error, term()}
  def prepare(%{"findings" => findings}, sources, previous, pass_id, observer) when is_list(findings) do
    if Enum.count_until(findings, 21) <= 20 do
      prepare_findings(findings, sources, previous, pass_id, observer)
    else
      {:error, :too_many_findings}
    end
  end

  def prepare(_, _, _, _, _), do: {:error, :malformed_agent_output}

  @spec prepare_findings([map()], [map()], [map()], String.t(), map()) :: {:ok, [tuple()]} | {:error, term()}
  defp prepare_findings(findings, sources, previous, pass_id, observer) do
    known = MapSet.new(previous, & &1["id"])
    prior = Map.new(previous, &{&1["id"], &1})
    source_map = Map.new(sources, &{&1["source_id"], &1})

    findings
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn {finding, index}, {:ok, docs, ids} ->
      with true <- is_map(finding),
           id = finding["id"] || Ecto.UUID.generate(),
           true <- is_nil(finding["id"]) or MapSet.member?(known, id),
           false <- MapSet.member?(ids, id),
           true <- Enum.all?(@fields, &(is_binary(finding[&1]) and byte_size(finding[&1]) <= 12_000)),
           true <- finding["title"] != "",
           {:ok, citations} <- citations(finding["citations"], source_map) do
        data =
          finding
          |> Map.take(@fields)
          |> Map.merge(%{
            "id" => id,
            "citations" => citations,
            "pass_id" => pass_id,
            "observer" => observer,
            "at" => DateTime.to_iso8601(DateTime.utc_now()),
            "provisional" => Enum.any?(citations, & &1["provisional"]),
            "projects" => references(citations, "project", prior[id], "projects"),
            "runs" => references(citations, "run_id", prior[id], "runs")
          })

        revision = {"revision/" <> pass_id <> "/" <> to_string(index), "revision/" <> id, data}
        {:cont, {:ok, docs ++ [{"finding/" <> id, "finding", data}, revision], MapSet.put(ids, id)}}
      else
        _ -> {:halt, {:error, :invalid_finding_or_citation}}
      end
    end)
    |> case do
      {:ok, docs, _ids} -> {:ok, docs}
      error -> error
    end
  end

  @spec references([map()], String.t(), map() | nil, String.t()) :: [String.t()]
  defp references(citations, field, prior, key) do
    Enum.uniq(Enum.map(citations, & &1[field]) ++ Map.get(prior || %{}, key, []))
  end

  @spec citations(term(), map()) :: {:ok, [map()]} | {:error, atom()}
  defp citations(citations, sources) when is_list(citations) and length(citations) in 1..20 do
    Enum.reduce_while(citations, {:ok, []}, fn citation, {:ok, result} ->
      with %{"source_id" => id, "excerpt" => excerpt} when is_binary(excerpt) and byte_size(excerpt) in 1..8000 <-
             citation,
           %{"text" => text} = source <- Map.get(sources, id),
           true <- String.contains?(text, excerpt) do
        {:cont, {:ok, result ++ [source |> Map.delete("text") |> Map.put("excerpt", excerpt)]}}
      else
        _ -> {:halt, {:error, :invalid_citation}}
      end
    end)
  end

  defp citations(_, _), do: {:error, :invalid_citation}
end
