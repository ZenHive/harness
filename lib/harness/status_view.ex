defmodule Harness.StatusView do
  @moduledoc """
  Human-readable fleet status for in-flight, repairing, green, and red runs.

  Aggregates live `Harness.Run.Status` snapshots and agent availability from
  `Harness.AgentRegistry`. Intended for `mix harness.status`, not JSON parsing.
  """

  alias Harness.AgentRegistry
  alias Harness.Cron.RoadmapPoller
  alias Harness.ResultStore
  alias Harness.Run
  alias Harness.Run.LogRecord
  alias Harness.Run.Status
  alias Harness.Run.Supervisor, as: RunSupervisor

  require Logger

  @type bucket :: :in_flight | :repairing | :green | :red

  @type run_entry :: %{
          status: Status.t(),
          bucket: bucket(),
          detail: String.t() | nil
        }

  @type t :: %{
          required(:runs) => [run_entry()],
          required(:unavailable_agents) => [{module(), term()}],
          optional(:history) => [run_entry()],
          optional(:cron_polling) => RoadmapPoller.cron_status()
        }

  # Most-recent settled runs surfaced as dashboard history (newest-first via
  # store `inserted_at` / file mtime ordering, capped at query time).
  @history_limit 200
  @run_status_timeout_ms 100

  @bucket_order [:in_flight, :repairing, :green, :red]

  @bucket_labels %{
    in_flight: "IN FLIGHT",
    repairing: "REPAIRING",
    green: "GREEN",
    red: "RED"
  }

  @doc "Collects the current fleet snapshot from registered runs and the agent registry."
  @spec snapshot() :: t()
  def snapshot do
    runs = live_runs()
    live_ids = MapSet.new(runs, & &1.status.run_id)

    %{
      runs: runs,
      history: history(live_ids),
      unavailable_agents: AgentRegistry.list_unavailable(),
      cron_polling: RoadmapPoller.status()
    }
  end

  @doc """
  The in-memory live-run entries — every registered `Harness.Run`'s status,
  classified into a bucket. No disk I/O (unlike `snapshot/0`, which also reads
  the persisted history). The dashboard seeds its active-run stream from this
  and recomputes it on each lifecycle event.
  """
  @spec live_runs() :: [run_entry()]
  def live_runs do
    Enum.flat_map(RunSupervisor.list_runs(), &run_entry/1)
  end

  @doc """
  Builds a `run_entry` (status + bucket + detail) from a `Harness.Run.Status`.

  The public builder the dashboard uses to turn a `RunFeed` lifecycle broadcast
  into a renderable row, shared with the live/history entry construction below.
  """
  @spec run_entry_for(Status.t()) :: run_entry()
  def run_entry_for(%Status{} = status) do
    %{status: status, bucket: classify(status), detail: detail(status)}
  end

  # Settled runs read back from the configured ResultStore, minus any run_id
  # still live (live entry wins — see snapshot/0). Best-effort: a store error
  # degrades to an empty history, never crashes the snapshot. render/1 and
  # bucket_counts/1 deliberately ignore this key so `mix harness.status` and the
  # topbar tallies stay "current fleet" — history is a dashboard-only surface.
  @spec history(MapSet.t()) :: [run_entry()]
  defp history(live_ids) do
    case ResultStore.list_run_records(limit: @history_limit) do
      {:ok, records} ->
        records
        |> Enum.reject(&MapSet.member?(live_ids, &1.run_id))
        |> Enum.filter(&settled?/1)
        |> Enum.map(&history_entry/1)

      {:error, reason} ->
        Logger.warning("harness status view: failed to list run records: #{inspect(reason)}")
        []
    end
  end

  # Settled records always persist a terminal state; anything else (a record
  # leaked by a stale schema or a misbehaving writer) is skipped so one bad
  # record never takes down the whole snapshot — and never displaces a good
  # record from the bounded history window.
  @spec settled?(LogRecord.t()) :: boolean()
  defp settled?(%LogRecord{state: state}) when state in [:done, :failed], do: true

  defp settled?(%LogRecord{} = record) do
    Logger.warning(
      "harness status view: skipping history record #{record.run_id} with non-terminal state #{inspect(record.state)}"
    )

    false
  end

  @spec history_entry(LogRecord.t()) :: run_entry()
  defp history_entry(%LogRecord{} = record) do
    record |> Status.from_log_record() |> run_entry_for()
  end

  @doc "Renders `snapshot/0` output for terminal display."
  @spec render(t()) :: String.t()
  def render(%{runs: runs, unavailable_agents: unavailable} = snapshot) do
    cron_status = Map.get(snapshot, :cron_polling, RoadmapPoller.status())

    sections =
      @bucket_order
      |> Enum.map(&render_bucket(&1, runs))
      |> Enum.reject(&(&1 == ""))

    body =
      case Enum.reject(sections ++ [render_unavailable(unavailable)], &(&1 == "")) do
        [] -> "  (no runs in flight or lingering)\n"
        lines -> Enum.join(lines, "\n\n") <> "\n"
      end

    "Harness fleet status\n" <> render_cron_status(cron_status) <> "\n\n" <> body
  end

  @doc "Classifies a run status into a human-facing bucket."
  @spec classify(Status.t()) :: bucket()
  def classify(%Status{state: :done}), do: :green
  def classify(%Status{state: :failed}), do: :red

  # A recovering/reviewing run IS red work being fixed — the human-facing
  # "being repaired" bucket, even though the fixer is now an AI agent.
  def classify(%Status{state: :recovering}), do: :repairing
  def classify(%Status{state: :reviewing}), do: :repairing

  def classify(%Status{state: state}) when state in [:dispatched, :running, :committing, :held], do: :in_flight

  @spec run_entry(String.t()) :: [run_entry()]
  defp run_entry(run_id) do
    case Run.status(run_id, @run_status_timeout_ms) do
      {:ok, status} -> [run_entry_for(status)]
      {:error, reason} when reason in [:not_found, :timeout] -> []
    end
  end

  @spec detail(Status.t()) :: String.t() | nil
  defp detail(%Status{state: :failed, reason: reason}) when not is_nil(reason), do: describe_reason(reason)

  defp detail(%Status{state: :held, hold_reason: reason}) when not is_nil(reason), do: "held #{reason}"

  defp detail(_), do: nil

  @spec describe_reason(term()) :: String.t()
  defp describe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp describe_reason({:unavailable, agent, model, opts}) when is_list(opts) do
    available = Keyword.get(opts, :available, [])

    suffix =
      case available do
        [] -> "none available"
        ids -> "available: #{Enum.join(ids, ", ")}"
      end

    "#{agent} model #{inspect(model)} unavailable (#{suffix})"
  end

  defp describe_reason({tag, inner}), do: "#{tag} #{inspect(inner)}"

  @spec render_bucket(bucket(), [run_entry()]) :: String.t()
  defp render_bucket(bucket, runs) do
    entries = Enum.filter(runs, &(&1.bucket == bucket))

    case entries do
      [] ->
        ""

      _ ->
        header = Map.fetch!(@bucket_labels, bucket) <> " (#{length(entries)})"
        lines = Enum.map(entries, &render_run/1)
        Enum.join([header | lines], "\n")
    end
  end

  @spec render_run(run_entry()) :: String.t()
  defp render_run(%{status: status, detail: detail}) do
    base = "  task #{status.task_id}  #{status.run_id}  #{status.state}"

    if detail do
      base <> "  #{detail}"
    else
      base
    end
  end

  @spec render_unavailable([{module(), term()}]) :: String.t()
  defp render_unavailable([]), do: ""

  defp render_unavailable(agents) do
    lines =
      Enum.map(agents, fn {adapter, reason} ->
        "  #{adapter_label(adapter)}  #{describe_unavailable(reason)}"
      end)

    Enum.join(["UNAVAILABLE AGENTS (#{length(agents)})" | lines], "\n")
  end

  @spec adapter_label(module()) :: String.t()
  defp adapter_label(module) do
    module |> Module.split() |> List.last()
  end

  @spec describe_unavailable(term()) :: String.t()
  defp describe_unavailable({:review_stuck, item_id, report}) when is_binary(report),
    do: "review stuck on #{item_id}: #{String.slice(report, 0, 120)}"

  defp describe_unavailable({:review_stuck, item_id, _report}), do: "review stuck on #{item_id}"

  defp describe_unavailable(reason), do: inspect(reason)

  @spec render_cron_status(RoadmapPoller.cron_status()) :: String.t()
  defp render_cron_status(:disabled), do: "Cron polling: disabled"

  defp render_cron_status({:enabled, schedule, %DateTime{} = tick}) do
    "Cron polling: next tick #{format_tick(tick)} (#{schedule})"
  end

  defp render_cron_status({:enabled, schedule, :unknown}) do
    "Cron polling: next tick unknown (#{schedule})"
  end

  defp render_cron_status({:invalid, schedule, reason}) do
    "Cron polling: invalid schedule #{inspect(schedule)} #{inspect(reason)}"
  end

  @spec format_tick(DateTime.t()) :: String.t()
  defp format_tick(%DateTime{} = tick) do
    tick
    |> DateTime.to_iso8601()
    |> String.replace("T", " ")
  end
end
