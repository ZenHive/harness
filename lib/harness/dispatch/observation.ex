defmodule Harness.Dispatch.Observation do
  @moduledoc "Run observation and bounded polling across live, queued, and persisted runs."

  import Ecto.Query, only: [from: 2]

  alias Harness.Dispatch.Presentation
  alias Harness.Dispatch.Submission
  alias Harness.ResultStore
  alias Harness.Run
  alias Harness.Run.LogRecord
  alias Harness.Run.Status
  alias Harness.Run.Worker, as: RunWorker
  alias Oban.Job

  @default_await_timeout_ms 1_800_000
  @await_runs_poll_ms 250
  @recommended_adapter "recommend"
  @run_worker Oban.Worker.to_string(RunWorker)
  @unfinished_oban_states ~w(available scheduled executing retryable)

  @spec await(String.t(), String.t(), String.t(), number(), boolean()) ::
          {:ok, map()} | {:error, Harness.Dispatch.error()}

  # Goes through the SAME Oban-guarded path as dispatch-task (`enqueue_start/4`),
  # so an await for a task already in flight attaches to the existing run — the
  # unique guard returns its run_id — instead of starting a duplicate, and the
  # worker writes rmap `in_progress`. The returned run_id is then awaited by
  # polling to settle (`await_result/2`): there is no subscriber push to receive
  # for a run this process did not start. `timeout_ms` is guarded `is_number`
  # (not `is_integer`): MCP/JSON callers deliver it as a float, which
  # `await_result/2` truncates; a bare `is_integer` would FunctionClause the whole
  # dispatch-await tool on any client-supplied timeout.
  @doc false
  def await(
        project_name,
        task,
        adapter \\ @recommended_adapter,
        timeout_ms \\ @default_await_timeout_ms,
        scrub_anthropic_key \\ true
      )
      when is_number(timeout_ms) and timeout_ms > 0 and is_boolean(scrub_anthropic_key) and is_binary(project_name) and
             is_binary(task) and is_binary(adapter) do
    with {:ok, run_id} <- Submission.enqueue_start(project_name, task, adapter, scrub_anthropic_key) do
      await_result(run_id, timeout_ms)
    end
  end

  @spec await_result(String.t(), number()) :: {:ok, map()}
  @doc false
  def await_result(run_id, timeout_ms) when is_binary(run_id) and is_number(timeout_ms) and timeout_ms > 0 do
    # MCP/JSON callers deliver the timeout as a float; the poll deadline and the
    # timeout summary both require an integer, so truncate once at the boundary.
    wait_ms = trunc(timeout_ms)
    poll_until_settled(run_id, System.monotonic_time(:millisecond) + wait_ms, wait_ms)
  end

  @spec poll_until_settled(String.t(), integer(), non_neg_integer()) :: {:ok, map()}
  defp poll_until_settled(run_id, deadline_ms, wait_ms) do
    case settled_await_summary(run_id) do
      {:ok, summary} ->
        {:ok, summary}

      :in_flight ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          {:ok, Presentation.timeout_summary(run_id, wait_ms)}
        else
          wait_for_next_poll(deadline_ms)
          poll_until_settled(run_id, deadline_ms, wait_ms)
        end
    end
  end

  # A run is settled once `status/1` reports a terminal state: `settle/2` persists
  # the run record BEFORE the run lingers, so a terminal status guarantees the
  # record is already readable — the rich summary (verdict/report/ratings + diff
  # sizes) comes from it. A run that failed to start never persists a record and
  # drops out of `status/1` as :not_found once its Oban job stops retrying — that
  # is the terminal "vanished" signal, not a still-in-flight one.
  @spec settled_await_summary(String.t()) :: {:ok, map()} | :in_flight
  defp settled_await_summary(run_id) do
    case status(run_id) do
      {:ok, %{state: state} = snapshot} when state in [:done, :failed] ->
        {:ok, settled_summary(run_id, snapshot)}

      {:ok, _in_flight} ->
        :in_flight

      {:error, :not_found} ->
        {:ok, Presentation.vanished_summary(run_id)}
    end
  end

  # Rebuilds summarize_result/1's shape from the persisted record (the poll-path
  # equivalent of the subscriber-push %Run.Result{} projection). Falls back to the
  # compact status snapshot only if the record is unexpectedly unreadable.
  @spec settled_summary(String.t(), map()) :: map()
  defp settled_summary(run_id, snapshot) do
    case ResultStore.list_run_records(run_id: run_id, limit: 1) do
      {:ok, [%LogRecord{} = record | _]} -> Presentation.record_await_summary(record)
      _none -> Presentation.snapshot_await_summary(snapshot)
    end
  end

  @spec await_runs([String.t()], number()) :: {:ok, [map()]}
  @doc false
  def await_runs(run_ids, timeout_ms \\ @default_await_timeout_ms)
      when is_list(run_ids) and is_number(timeout_ms) and timeout_ms > 0 do
    wait_ms = trunc(timeout_ms)
    deadline_ms = System.monotonic_time(:millisecond) + wait_ms

    await_runs_until(run_ids, deadline_ms)
  end

  @spec status(String.t()) :: {:ok, map()} | {:error, :not_found}
  @doc false
  def status(run_id) when is_binary(run_id) do
    case Run.status(run_id) do
      {:ok, value} ->
        {:ok, Presentation.summarize_status(value)}

      # Not live: try an unfinished Oban job (queued/dispatched), then the
      # persisted settled record. Without the last fallback a run that already
      # SETTLED — done or failed, the common case for an aged-out run_id —
      # answers :not_found for its own id, which reads as "no such run".
      {:error, :not_found} ->
        with {:error, :not_found} <- oban_job_status(run_id) do
          settled_run_status(run_id)
        end
    end
  end

  @spec verdict_detail(String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  @doc false
  def verdict_detail(run_id) when is_binary(run_id) do
    case ResultStore.list_run_records(run_id: run_id) do
      {:ok, [%LogRecord{} = record | _]} -> {:ok, Presentation.summarize_verdict_detail(record)}
      {:ok, []} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec await_runs_until([String.t()], integer()) :: {:ok, [map()]}
  defp await_runs_until(run_ids, deadline_ms) do
    summaries = Enum.map(run_ids, &await_run_summary/1)

    cond do
      Enum.all?(summaries, &await_run_complete?/1) ->
        {:ok, summaries}

      System.monotonic_time(:millisecond) >= deadline_ms ->
        {:ok, Enum.map(summaries, &Presentation.timeout_unfinished_run/1)}

      true ->
        wait_for_next_poll(deadline_ms)
        await_runs_until(run_ids, deadline_ms)
    end
  end

  @spec await_run_summary(String.t()) :: map()
  defp await_run_summary(run_id) do
    case status(run_id) do
      {:ok, summary} -> Presentation.compact_run_summary(summary)
      {:error, :not_found} -> Presentation.not_found_summary(run_id)
    end
  end

  @spec await_run_complete?(map()) :: boolean()
  defp await_run_complete?(%{state: state}), do: state in [:done, :failed, :not_found]

  @spec wait_for_next_poll(integer()) :: :ok
  defp wait_for_next_poll(deadline_ms) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
    after
      min(@await_runs_poll_ms, remaining_ms) -> :ok
    end
  end

  @spec oban_job_status(String.t()) :: {:ok, map()} | {:error, :not_found}
  defp oban_job_status(run_id) do
    case lookup_oban_run_job(run_id) do
      {:ok, %Job{} = job} -> {:ok, Presentation.summarize_oban_job_status(job)}
      {:error, :not_found} = error -> error
    end
  end

  # Last fallback for a run that is neither live nor queued: its persisted
  # settled record. Rehydrates the same status shape from the LogRecord so a
  # done/failed run reports its terminal state instead of :not_found.
  @spec settled_run_status(String.t()) :: {:ok, map()} | {:error, :not_found}
  defp settled_run_status(run_id) do
    case ResultStore.list_run_records(run_id: run_id, limit: 1) do
      {:ok, [%LogRecord{} = record | _]} ->
        {:ok, record |> Status.from_log_record() |> Presentation.summarize_status()}

      _none ->
        {:error, :not_found}
    end
  end

  @spec lookup_oban_run_job(String.t()) :: {:ok, Job.t()} | {:error, :not_found}
  defp lookup_oban_run_job(run_id) do
    case Application.get_env(:harness, :oban_run_job_lookup) do
      fun when is_function(fun, 1) -> fun.(run_id)
      _other -> query_oban_run_job(run_id)
    end
  end

  @spec query_oban_run_job(String.t()) :: {:ok, Job.t()} | {:error, :not_found}
  defp query_oban_run_job(run_id) do
    query =
      from(job in Job,
        where:
          job.worker == ^@run_worker and job.state in ^@unfinished_oban_states and
            fragment("?->>? = ?", job.args, "run_id", ^run_id),
        order_by: [desc: job.inserted_at],
        limit: 1
      )

    case Harness.Repo.one(query) do
      %Job{} = job -> {:ok, job}
      nil -> {:error, :not_found}
    end
  rescue
    # Repo/Oban not running (RuntimeError) or a DB query failure → treat as "no
    # job". A genuine code bug stays unlisted so it crashes instead of vanishing.
    _error in [
      RuntimeError,
      DBConnection.ConnectionError,
      DBConnection.OwnershipError,
      Postgrex.Error,
      Ecto.QueryError,
      ArgumentError
    ] ->
      {:error, :not_found}
  end
end
