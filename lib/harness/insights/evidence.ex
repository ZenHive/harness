defmodule Harness.Insights.Evidence do
  @moduledoc "Bounded, read-only run evidence; never exposes lifecycle or roadmap operations."
  import Ecto.Query

  alias Harness.Dispatch
  alias Harness.Insights.Store
  alias Harness.ProjectRegistry
  alias Harness.Repo
  alias Harness.ResultStore
  alias Harness.ResultStore.Memory
  alias Harness.ResultStore.Schema.RunRecord

  @batch 12
  @excerpt 8000

  @doc "Reads a durable scan page and a bounded page of active runs."
  @spec batch(map()) :: {:ok, map()} | {:error, term()}
  def batch(progress) do
    bootstrap = Map.get(progress, "bootstrap", DateTime.utc_now() |> DateTime.shift(week: -1) |> DateTime.to_iso8601())
    projects = Enum.map(ProjectRegistry.list(), & &1.name)
    cursor = Map.get(progress, "cursor", "")

    with {:ok, records, history_partial} <- records(projects, bootstrap, cursor) do
      active_ids = Enum.sort(Harness.Run.Supervisor.list_runs())
      active_cursor = Map.get(progress, "active_cursor", "")
      active_page = active_ids |> Enum.filter(&(&1 > active_cursor)) |> Enum.take(@batch + 1)
      active_partial = length(active_page) > @batch
      active_page = Enum.take(active_page, @batch)
      historical = Enum.map(records, &historical/1)
      active = active_page |> Enum.map(&active/1) |> Enum.filter(&included?(&1, projects))
      samples = historical ++ active
      changed = Enum.reject(samples, &(Store.get("seen/" <> &1.key) == %{"digest" => &1.digest}))
      snapshots = Enum.flat_map(changed, & &1.sources)
      sources = Enum.map(snapshots, &Map.delete(&1, "content"))
      incomplete = Enum.any?(Enum.flat_map(samples, & &1.sources), &(&1["availability"] != "available"))
      cycle_incomplete = Map.get(progress, "cycle_incomplete", false) or incomplete
      pending = history_partial or active_partial

      next = %{
        "bootstrap" => bootstrap,
        "cursor" => if(history_partial, do: List.last(records).run_id, else: ""),
        "active_cursor" => if(active_partial, do: List.last(active_page), else: ""),
        "cycle_incomplete" => pending and cycle_incomplete,
        "scanned" => Map.get(progress, "scanned", 0) + length(samples)
      }

      {:ok,
       %{
         sources: sources,
         snapshots: snapshots,
         next: next,
         changed: length(changed),
         partial: pending or cycle_incomplete,
         pending: pending,
         seen: Enum.map(changed, &{"seen/" <> &1.key, "seen", %{"digest" => &1.digest}})
       }}
    end
  end

  @spec included?(map(), [String.t()]) :: boolean()
  defp included?(sample, projects) do
    sample.sources != [] and (is_nil(sample.project) or sample.project in projects)
  end

  @spec records([String.t()], String.t(), String.t()) :: {:ok, [map()], boolean()} | {:error, term()}
  defp records(projects, bootstrap, cursor) do
    if Store.persistent?() do
      {:ok, date, _} = DateTime.from_iso8601(bootstrap)
      date = DateTime.to_naive(date)

      rows =
        Repo.all(
          from r in RunRecord,
            where: r.project_name in ^projects and r.updated_at >= ^date and r.run_id > ^cursor,
            order_by: r.run_id,
            limit: ^(@batch + 1),
            select: r
        )

      {:ok, Enum.take(rows, @batch), length(rows) > @batch}
    else
      {:ok, since, _} = DateTime.from_iso8601(bootstrap)

      case ResultStore.configured() do
        {Memory, opts} -> memory_records(projects, since, cursor, opts)
        Memory -> memory_records(projects, since, cursor, [])
        store when store in [nil, false] -> {:ok, [], false}
        _ -> {:error, :unsupported_observer_history_backend}
      end
    end
  end

  @spec memory_records([String.t()], DateTime.t(), String.t(), keyword()) :: {:ok, [map()], boolean()}
  defp memory_records(projects, since, cursor, opts) do
    rows = Memory.observation_page(cursor, projects, since, @batch + 1, opts)
    {:ok, Enum.take(rows, @batch), length(rows) > @batch}
  end

  @spec historical(map()) :: map()
  defp historical(record) do
    facts = Map.drop(record, [:__struct__, :__meta__, :agent_output, :reviewer_output])

    sources = [
      snapshot_source(
        record.run_id,
        record.project_name,
        "record",
        inspect(facts, limit: :infinity, printable_limit: :infinity),
        false
      ),
      snapshot_source(record.run_id, record.project_name, "agent_output", record.agent_output, false),
      snapshot_source(record.run_id, record.project_name, "reviewer_output", record.reviewer_output, false)
    ]

    sample("record/" <> record.run_id, record.project_name, sources)
  end

  @spec active(String.t()) :: map()
  defp active(id) do
    case Dispatch.status(id) do
      {:ok, %{state: state}} when state in [:done, :failed, "done", "failed"] ->
        sample("active/" <> id, nil, [])

      {:ok, status} ->
        provisional = status.state not in [:done, :failed, "done", "failed"]

        transcript =
          case Dispatch.transcript(id) do
            {:ok, %{transcript: text}} -> text
            {:error, :not_found} -> nil
          end

        sources = [
          snapshot_source(
            id,
            status.project_name,
            "status",
            inspect(status, limit: :infinity, printable_limit: :infinity),
            provisional
          ),
          snapshot_source(id, status.project_name, "transcript", transcript, provisional)
        ]

        sample("active/" <> id, status.project_name, sources)

      {:error, :not_found} ->
        sample("active/" <> id, nil, [snapshot_source(id, nil, "status", nil, true)])
    end
  end

  @spec snapshot_source(String.t(), String.t() | nil, String.t(), String.t() | nil, boolean()) :: map()
  defp snapshot_source(id, project, field, text, provisional) do
    Map.put(source(id, project, field, text, provisional), "content", text || "")
  end

  @doc "Constructs a retained excerpt with an explicit availability witness."
  @spec source(String.t(), String.t() | nil, String.t(), String.t() | nil, boolean()) :: map()
  def source(id, project, field, text, provisional) do
    availability =
      cond do
        text in [nil, ""] -> "unavailable"
        byte_size(text) > @excerpt -> "truncated"
        true -> "available"
      end

    content_hash = :sha256 |> :crypto.hash(text || "") |> Base.encode16()

    content = text || ""
    text = excerpt(text)

    %{
      "source_id" => id <> "/" <> field,
      "run_id" => id,
      "project" => project,
      "field" => field,
      "text" => text,
      "availability" => availability,
      "provisional" => provisional,
      "content_hash" => content_hash,
      "total_bytes" => byte_size(content),
      "offset" => 0,
      "next_offset" => if(byte_size(text) < byte_size(content), do: byte_size(text))
    }
  end

  @spec excerpt(String.t() | nil) :: String.t()
  defp excerpt(nil), do: ""
  defp excerpt(text), do: valid_prefix(text, min(byte_size(text), @excerpt))

  @spec valid_prefix(String.t(), non_neg_integer()) :: String.t()
  defp valid_prefix(text, length) do
    prefix = binary_part(text, 0, length)
    if String.valid?(prefix), do: prefix, else: valid_prefix(text, length - 1)
  end

  @doc "Reads a bounded continuation from this pass's immutable source snapshot."
  @spec read(map(), String.t(), non_neg_integer()) :: {:ok, map()} | {:error, atom()}
  def read(batch, id, offset) when is_integer(offset) and offset >= 0 do
    case Enum.find(batch.snapshots, &(&1["source_id"] == id)) do
      %{"content" => content} = source when offset < byte_size(content) ->
        remainder = binary_part(content, offset, byte_size(content) - offset)

        if String.valid?(remainder) do
          text = excerpt(remainder)
          next = offset + byte_size(text)

          {:ok,
           source
           |> Map.delete("content")
           |> Map.merge(%{
             "source_id" => id <> "@" <> to_string(offset),
             "text" => text,
             "offset" => offset,
             "next_offset" => if(next < byte_size(content), do: next),
             "root_source_id" => id,
             "availability" => if(next < byte_size(content), do: "truncated", else: "available")
           })}
        else
          {:error, :invalid_source_offset}
        end

      _ ->
        {:error, :unknown_source_or_offset}
    end
  end

  def read(_, _, _), do: {:error, :invalid_source_offset}

  @spec sample(String.t(), String.t() | nil, [map()]) :: map()
  defp sample(key, project, sources) do
    digest = :sha256 |> :crypto.hash(:erlang.term_to_binary(sources)) |> Base.encode16()
    %{key: key, project: project, sources: sources, digest: digest}
  end
end
