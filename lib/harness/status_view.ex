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
  alias Harness.Run.Result
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

  # Most-recent settled runs surfaced as dashboard history. run_ids embed an
  # epoch-ms component, so a descending string sort is a recency proxy; capped
  # so an unbounded ~/.harness/results never bloats the snapshot.
  @history_limit 200

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
    runs = Enum.flat_map(RunSupervisor.list_runs(), &run_entry/1)
    live_ids = MapSet.new(runs, & &1.status.run_id)

    %{
      runs: runs,
      history: history(live_ids),
      unavailable_agents: AgentRegistry.list_unavailable(),
      cron_polling: RoadmapPoller.status()
    }
  end

  # Settled runs read back from the configured ResultStore, minus any run_id
  # still live (live entry wins — see snapshot/0). Best-effort: a store error
  # degrades to an empty history, never crashes the snapshot. render/1 and
  # bucket_counts/1 deliberately ignore this key so `mix harness.status` and the
  # topbar tallies stay "current fleet" — history is a dashboard-only surface.
  @spec history(MapSet.t()) :: [run_entry()]
  defp history(live_ids) do
    case ResultStore.list_run_records() do
      {:ok, records} ->
        records
        |> Enum.reject(&MapSet.member?(live_ids, &1.run_id))
        |> Enum.sort_by(& &1.run_id, :desc)
        |> Enum.take(@history_limit)
        |> Enum.map(&history_entry/1)

      {:error, reason} ->
        Logger.warning("harness status view: failed to list run records: #{inspect(reason)}")
        []
    end
  end

  @spec history_entry(LogRecord.t()) :: run_entry()
  defp history_entry(%LogRecord{} = record) do
    status = Status.from_log_record(record)
    %{status: status, bucket: classify(status), detail: detail(status)}
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

  def classify(%Status{state: state, repair_attempts: attempts})
      when state in [:dispatched, :running, :committing, :verifying] and attempts > 0,
      do: :repairing

  def classify(%Status{state: state}) when state in [:dispatched, :running, :committing, :verifying], do: :in_flight

  @spec run_entry(String.t()) :: [run_entry()]
  defp run_entry(run_id) do
    case Run.status(run_id) do
      {:ok, status} ->
        [%{status: status, bucket: classify(status), detail: detail(status)}]

      {:error, :not_found} ->
        []
    end
  end

  @spec detail(Status.t()) :: String.t() | nil
  defp detail(%Status{state: :failed, reason: reason}) when not is_nil(reason), do: describe_reason(reason)

  defp detail(%Status{state: state, repair_attempts: attempts}) when state not in [:done, :failed] and attempts > 0,
    do: "attempt #{attempts}"

  defp detail(_), do: nil

  @spec describe_reason(Result.reason()) :: String.t()
  defp describe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

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
        header <> "\n" <> Enum.join(lines, "\n")
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

    "UNAVAILABLE AGENTS (#{length(agents)})\n" <> Enum.join(lines, "\n")
  end

  @spec adapter_label(module()) :: String.t()
  defp adapter_label(module) do
    module |> Module.split() |> List.last()
  end

  @spec describe_unavailable(term()) :: String.t()
  defp describe_unavailable({:quota_exhausted, kind}), do: "quota exhausted (#{kind})"

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
