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
      sources = Enum.flat_map(changed, & &1.sources)
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
            select: %{
              run_id: r.run_id,
              project_name: r.project_name,
              state: r.state,
              verdict: r.verdict,
              reviewer_diff_size: r.reviewer_diff_size,
              review_report: fragment("substring(? from 1 for 8000)", r.review_report),
              recovery_repaired: fragment("substring(? from 1 for 8000)", r.recovery_repaired),
              recovery_attempts: r.recovery_attempts,
              recovery_outcome: r.recovery_outcome,
              landed_sha: r.landed_sha,
              cold_check: r.cold_check,
              approved_then_found_red: r.approved_then_found_red,
              agent_output_hash: fragment("md5(?)", r.agent_output),
              reviewer_output_hash: fragment("md5(?)", r.reviewer_output),
              agent_output: fragment("substring(? from 1 for 8001)", r.agent_output),
              reviewer_output: fragment("substring(? from 1 for 8001)", r.reviewer_output)
            }
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
    facts =
      Map.take(record, [
        :state,
        :verdict,
        :reviewer_diff_size,
        :review_report,
        :recovery_attempts,
        :recovery_outcome,
        :recovery_repaired,
        :landed_sha,
        :cold_check,
        :approved_then_found_red,
        :agent_output_hash,
        :reviewer_output_hash
      ])

    sources = [
      source(record.run_id, record.project_name, "record", inspect(facts, limit: :infinity), false),
      source(record.run_id, record.project_name, "agent_output", record.agent_output, false),
      source(record.run_id, record.project_name, "reviewer_output", record.reviewer_output, false)
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
          source(id, status.project_name, "status", inspect(status, limit: :infinity), provisional),
          source(id, status.project_name, "transcript", transcript, provisional)
        ]

        sample("active/" <> id, status.project_name, sources)

      {:error, :not_found} ->
        sample("active/" <> id, nil, [source(id, nil, "status", nil, true)])
    end
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

    text = excerpt(text)

    %{
      "source_id" => id <> "/" <> field,
      "run_id" => id,
      "project" => project,
      "field" => field,
      "text" => text,
      "availability" => availability,
      "provisional" => provisional,
      "content_hash" => content_hash
    }
  end

  @spec excerpt(String.t() | nil) :: String.t()
  defp excerpt(nil), do: ""
  defp excerpt(text), do: text |> binary_part(0, min(byte_size(text), @excerpt)) |> String.replace_invalid()

  @spec sample(String.t(), String.t() | nil, [map()]) :: map()
  defp sample(key, project, sources) do
    digest = :sha256 |> :crypto.hash(:erlang.term_to_binary(sources)) |> Base.encode16()
    %{key: key, project: project, sources: sources, digest: digest}
  end
end
