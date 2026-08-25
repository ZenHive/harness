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

  # Total map from a settle-reason *head* to a fixed operator sentence. Lookup
  # is by atom (bare reason) or `elem(reason, 0)` (tuple reason). Inner terms
  # are never interpolated — they stay behind the run-detail raw disclosure.
  @reason_headlines %{
    approved: "Reviewer approved the work",
    review_stuck: "Reviewer produced no verdict",
    review_rejected: "Reviewer rejected the work",
    checkout_polluted: "Agent wrote outside the run worktree",
    checkout_pollution_check_failed: "Checkout pollution check failed",
    cancelled: "Run was cancelled",
    timed_out: "Run lifetime elapsed",
    memory_runaway: "Run exceeded the memory ceiling",
    hold_expired: "Held run outlived the hold safeguard",
    reflex_halted: "Reflex layer halted the agent",
    redispatched: "Run was superseded by a successor",
    blocked: "Task was marked blocked",
    worktree_failed: "Worktree could not be created",
    agent_spawn_failed: "Agent never spawned",
    driver_crashed: "Agent driver crashed",
    commit_failed: "Work could not be committed",
    run_crashed: "Run process exited before a result",
    no_available_agent: "No adapter was available",
    model_required: "Reviewer has no configured model",
    unavailable: "Configured model is unavailable"
  }

  # Fixed recovery primitive named from the same reason head. Unmapped heads
  # fall through to resume_failed — the general "continue from the retained
  # branch" primitive — never a scored/keyword pick.
  @reason_recovery %{
    review_stuck: "dispatch-rereview",
    review_rejected: "dispatch-resume_failed",
    checkout_polluted: "dispatch-resume_failed",
    checkout_pollution_check_failed: "dispatch-resume_failed",
    cancelled: "dispatch-resume_failed",
    timed_out: "dispatch-resume_failed",
    memory_runaway: "dispatch-resume_failed",
    hold_expired: "dispatch-resume_failed",
    reflex_halted: "dispatch-resume_failed",
    redispatched: "cancel",
    blocked: "dispatch-reland",
    worktree_failed: "cancel",
    agent_spawn_failed: "dispatch-resume_failed",
    driver_crashed: "dispatch-resume_failed",
    commit_failed: "dispatch-resume_failed",
    run_crashed: "dispatch-rereview",
    no_available_agent: "cancel",
    model_required: "dispatch-rereview",
    unavailable: "dispatch-rereview"
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
        lines -> IO.iodata_to_binary([Enum.intersperse(lines, "\n\n"), "\n"])
      end

    IO.iodata_to_binary(["Harness fleet status\n", render_cron_status(cron_status), "\n\n", body])
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

  @doc """
  Operator-language headline for a settle reason.

  Looks up a fixed sentence from the reason's head atom (the bare atom, or
  `elem(reason, 0)` for a tuple). Unmapped shapes fall through to `inspect/1`
  so a display formatter never crashes on an older persisted record.
  """
  @spec describe_reason(term()) :: String.t()
  def describe_reason(reason) do
    case Map.get(@reason_headlines, reason_head(reason)) do
      nil -> inspect(reason)
      headline -> headline
    end
  end

  @doc """
  Operator copy for a failed run: headline, consequence, named recovery
  primitive, and the raw reason term.

  The headline is `describe_reason/1` so the index cell and the run-detail
  page render the same failure text. The consequence line reports whether
  the implementer's `harness/<run-id>` commits were retained, read from the
  run status (`worktree_path` or a `:committing`/`:reviewing` entered-at
  stamp) — not from reviewer prose.
  """
  @spec failure_copy(Status.t()) :: %{
          headline: String.t(),
          consequence: String.t(),
          recovery: String.t(),
          raw: String.t()
        }
  def failure_copy(%Status{reason: reason} = status) do
    %{
      headline: describe_reason(reason),
      consequence: consequence_line(status),
      recovery: recommend_recovery(reason),
      raw: inspect(reason)
    }
  end

  @spec reason_head(term()) :: atom() | nil
  defp reason_head(reason) when is_atom(reason), do: reason

  defp reason_head(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      head when is_atom(head) -> head
      _ -> nil
    end
  end

  defp reason_head(_reason), do: nil

  @spec recommend_recovery(term()) :: String.t()
  defp recommend_recovery(reason) do
    Map.get(@reason_recovery, reason_head(reason), "dispatch-resume_failed")
  end

  @spec consequence_line(Status.t()) :: String.t()
  defp consequence_line(%Status{run_id: run_id} = status) do
    branch = "harness/" <> run_id

    if branch_retained?(status) do
      "The implementer's commits on #{branch} are retained."
    else
      "No implementer commits were retained on #{branch}."
    end
  end

  @spec branch_retained?(Status.t()) :: boolean()
  defp branch_retained?(%Status{worktree_path: path}) when is_binary(path) and path != "", do: true

  defp branch_retained?(%Status{state_entered_at: entered}) when is_map(entered) do
    Map.has_key?(entered, :committing) or Map.has_key?(entered, :reviewing)
  end

  defp branch_retained?(_status), do: false

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
