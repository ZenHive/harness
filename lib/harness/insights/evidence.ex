defmodule Harness.Insights.Evidence do
  @moduledoc "Bounded, read-only run evidence; never exposes lifecycle or roadmap operations."
  import Ecto.Query

  alias Harness.Audit.QAAttempt
  alias Harness.Dispatch
  alias Harness.Insights.ProjectEvidence
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
      collect(progress, bootstrap, projects, records, history_partial)
    end
  end

  @spec collect(map(), String.t(), [String.t()], [map()], boolean()) :: {:ok, map()}
  defp collect(progress, bootstrap, projects, records, history_partial) do
    active_ids = Enum.sort(Harness.Run.Supervisor.list_runs())
    active_cursor = Map.get(progress, "active_cursor", "")
    active_page = active_ids |> Enum.filter(&(&1 > active_cursor)) |> Enum.take(@batch + 1)
    active_partial = length(active_page) > @batch
    active_page = Enum.take(active_page, @batch)
    historical = Enum.map(records, &historical/1)
    active = active_page |> Enum.map(&active/1) |> Enum.filter(&included?(&1, projects))
    {qa, qa_next, qa_pending} = qa(projects, progress)
    relevant = Enum.map(historical ++ active ++ qa, & &1.project)
    {external, external_next, external_pending} = external(progress, relevant)

    finish(progress, bootstrap, historical ++ active ++ external ++ qa, %{
      records: records,
      historical: historical,
      active: active,
      active_page: active_page,
      history_partial: history_partial,
      active_partial: active_partial,
      qa_next: qa_next,
      qa_pending: qa_pending,
      external_next: external_next,
      external_pending: external_pending
    })
  end

  @spec finish(map(), String.t(), [map()], map()) :: {:ok, map()}
  defp finish(progress, bootstrap, samples, meta) do
    changed = Enum.reject(samples, &(Store.get("seen/" <> &1.key) == %{"digest" => &1.digest}))
    snapshots = snapshots(changed, samples)
    sources = snapshots |> Enum.take(@batch) |> Enum.map(&Map.delete(&1, "content"))
    incomplete = incomplete?(samples)
    cycle_incomplete = Map.get(progress, "cycle_incomplete", false) or incomplete
    pending = pending?(meta)

    {:ok,
     %{
       sources: sources,
       snapshots: snapshots,
       catalog: Enum.map(snapshots, &Map.drop(&1, ["text", "content"])),
       next: next_progress(progress, bootstrap, pending, cycle_incomplete, meta),
       changed: Enum.count(changed),
       changed_runs: Enum.count(changed, &run_sample?/1),
       partial: pending or cycle_incomplete,
       pending: pending,
       seen: Enum.map(changed, &{"seen/" <> &1.key, "seen", %{"digest" => &1.digest}})
     }}
  end

  @spec snapshots([map()], [map()]) :: [map()]
  defp snapshots([], _samples), do: []
  defp snapshots(changed, samples), do: Enum.flat_map(changed ++ (samples -- changed), & &1.sources)

  @spec incomplete?([map()]) :: boolean()
  defp incomplete?(samples) do
    sources = Enum.flat_map(samples, & &1.sources)

    Enum.count_until(sources, @batch + 1) > @batch or
      Enum.any?(sources, &(&1["availability"] != "available"))
  end

  @spec pending?(map()) :: boolean()
  defp pending?(meta) do
    meta.history_partial or meta.active_partial or meta.external_pending or meta.qa_pending
  end

  @spec run_sample?(map()) :: boolean()
  defp run_sample?(sample) do
    String.starts_with?(sample.key, "record/") or String.starts_with?(sample.key, "active/")
  end

  @spec next_progress(map(), String.t(), boolean(), boolean(), map()) :: map()
  defp next_progress(progress, bootstrap, pending, cycle_incomplete, meta) do
    %{
      "bootstrap" => bootstrap,
      "project_cursor" => meta.external_next,
      "qa_cursor" => meta.qa_next,
      "cursor" => last_cursor(meta.history_partial, meta.records, & &1.run_id),
      "active_cursor" => last_cursor(meta.active_partial, meta.active_page, & &1),
      "cycle_incomplete" => pending and cycle_incomplete,
      "scanned" => Map.get(progress, "scanned", 0) + Enum.count(meta.historical) + Enum.count(meta.active)
    }
  end

  @spec last_cursor(boolean(), [term()], (term() -> String.t())) :: String.t()
  defp last_cursor(false, _items, _fun), do: ""
  defp last_cursor(true, items, fun), do: fun.(List.last(items))

  @spec external(map(), [String.t()]) :: {[map()], String.t(), boolean()}
  defp external(progress, relevant) do
    projects = Enum.sort_by(ProjectRegistry.list(), & &1.name)
    page = projects |> Enum.filter(&(&1.name > Map.get(progress, "project_cursor", ""))) |> Enum.take(2)

    samples =
      (Enum.take(page, 1) ++ Enum.filter(projects, &(&1.name in relevant)))
      |> Enum.uniq_by(& &1.name)
      |> Enum.map(fn project ->
        sources = ProjectEvidence.sources(project)
        value = sample("project/" <> project.name, project.name, sources)
        # An unrelated commit changes attribution, not the evidence requiring reassessment.
        digest =
          sources
          |> Enum.map(&Map.take(&1, ["field", "content_hash", "availability", "unavailable_reason"]))
          |> :erlang.term_to_binary()
          |> then(&:crypto.hash(:sha256, &1))
          |> Base.encode16()

        %{value | digest: digest}
      end)

    {cursor, pending?} =
      case page do
        [first, _second | _] -> {first.name, true}
        _ -> {"", false}
      end

    {samples, cursor, pending?}
  end

  @spec qa([String.t()], map()) :: {[map()], String.t(), boolean()}
  defp qa(projects, progress) do
    if Store.persistent?() do
      cursor = Map.get(progress, "qa_cursor", "")
      query = from a in QAAttempt, where: a.project_name in ^projects, order_by: a.id, limit: ^(@batch + 1)
      query = if cursor == "", do: query, else: from(a in query, where: a.id > ^cursor)
      rows = Repo.all(query)
      page = Enum.take(rows, @batch)

      samples =
        Enum.map(page, fn row ->
          content =
            row |> Map.from_struct() |> Map.delete(:__meta__) |> inspect(limit: :infinity, printable_limit: :infinity)

          source =
            ProjectEvidence.snapshot(row.project_name, row.revision, "qa/" <> row.id, content, %{
              "authority" => "qa_attempt",
              "provenance" => "audit_qa_attempts/" <> row.id,
              "provisional" => row.status == "running"
            })

          sample("qa/" <> row.id, row.project_name, [source])
        end)

      {samples, if(length(rows) > @batch, do: List.last(page).id, else: ""), length(rows) > @batch}
    else
      {[], "", false}
    end
  end

  @doc "Lists bounded metadata for the immutable snapshots available in this pass."
  @spec catalog(map(), non_neg_integer()) :: map()
  def catalog(batch, offset) do
    page = Enum.slice(batch.catalog, offset, 20)
    %{"source_catalog" => page, "catalog_next_offset" => if(length(batch.catalog) > offset + 20, do: offset + 20)}
  end

  @doc "Locates a numbered task in the supplied immutable roadmap, without reading a path."
  @spec task(map(), String.t(), non_neg_integer()) :: {:ok, map()} | {:error, atom()}
  def task(batch, id, number) do
    case Enum.find(batch.snapshots, &(&1["source_id"] == id and &1["authority"] == "current_intent")) do
      %{"content" => content} ->
        case :binary.match(content, ~s([[task]]\nid = "#{number}"\n)) do
          {offset, _} -> read(batch, id, offset)
          :nomatch -> {:error, :unknown_task}
        end

      _ ->
        {:error, :unknown_source_or_offset}
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
      %{"content" => ""} = source when offset == 0 ->
        {:ok, Map.delete(source, "content")}

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
