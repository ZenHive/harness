defmodule Harness.Dispatch.Presentation do
  @moduledoc "Pure projections of run, review, routing, and dispatch data for driver clients."

  alias Harness.AgentKPI
  alias Harness.Batch.AgentEvaluation.Comparison
  alias Harness.Batch.AgentEvaluation.Entry
  alias Harness.CapabilityScore
  alias Harness.Cron.PendingDispatch
  alias Harness.Dispatch.AwaitRunsSummary
  alias Harness.Dispatch.RunSummary
  alias Harness.Run
  alias Harness.Run.LogRecord
  alias Harness.Run.Review
  alias Harness.Run.Status
  alias Harness.Run.TranscriptSnapshot
  alias Oban.Job

  @spec record_await_summary(LogRecord.t()) :: RunSummary.t()
  @doc false
  def record_await_summary(%LogRecord{} = record) do
    status = Status.from_log_record(record)

    %RunSummary{
      run_id: record.run_id,
      task_id: record.task_id,
      state: status.state,
      reason: status.reason,
      passed: status.state == :done,
      agent_diff_size: record.agent_diff_size,
      reviewer_diff_size: record.reviewer_diff_size,
      worktree_path: nil,
      review: record_review_summary(record)
    }
  end

  @spec record_review_summary(LogRecord.t()) :: map() | nil
  defp record_review_summary(%LogRecord{verdict: nil}), do: nil

  defp record_review_summary(%LogRecord{} = record) do
    %{
      verdict: record.verdict,
      report: record.review_report,
      dispatch_decision: record.dispatch_decision,
      ratings: AgentKPI.record_ratings(record),
      checks: record.review_checks,
      concerns: record.review_concerns,
      proposed_tasks: record.review_proposed_tasks,
      review_warning: record.review_warning?
    }
  end

  # A terminal run whose record could not be read, and a run that vanished before
  # persisting any record — both summarised from what status/1 still knows, with
  # the review detail absent (it lived only on the missing record).
  @spec snapshot_await_summary(map()) :: RunSummary.t()
  @doc false
  def snapshot_await_summary(%{run_id: run_id, state: state} = snapshot) do
    %RunSummary{
      run_id: run_id,
      task_id: Map.get(snapshot, :task_id),
      state: state,
      reason: Map.get(snapshot, :reason),
      passed: state == :done,
      agent_diff_size: nil,
      reviewer_diff_size: nil,
      worktree_path: nil,
      review: nil
    }
  end

  @spec vanished_summary(String.t()) :: map()
  @doc false
  def vanished_summary(run_id) do
    snapshot_await_summary(%{run_id: run_id, state: :failed, reason: :not_found})
  end

  @spec prior_attempt_section(LogRecord.t()) :: String.t()
  @doc false
  def prior_attempt_section(%LogRecord{review_report: report}) when is_binary(report) and report != "" do
    """
    ## Prior attempt failed — reviewer report

    #{report}

    The prior attempt's commits are already present (this run branches off them). Address the issues above and finish the task.
    """
  end

  @doc false
  def prior_attempt_section(%LogRecord{reason: reason}) do
    """
    ## Prior attempt failed

    The previous run did not complete: #{resume_reason_text(reason)}

    The prior attempt's commits are already present (this run branches off them). Continue from there and finish the task.
    """
  end

  @spec resume_reason_text(Run.Result.reason()) :: String.t()
  defp resume_reason_text({tag, detail}) when tag in [:review_stuck, :review_rejected] and is_binary(detail), do: detail

  defp resume_reason_text(reason), do: inspect(reason)

  @spec summarize_assessment(CapabilityScore.Assessment.t()) :: map()
  @doc false
  def summarize_assessment(%CapabilityScore.Assessment{} = assessment) do
    %{
      assessed_at: assessment.assessed_at,
      record_count: assessment.record_count,
      entries:
        Enum.map(assessment.entries, fn %CapabilityScore.Entry{} = entry ->
          %{
            facet: entry.facet,
            winner: entry.winner,
            reasoning: entry.reasoning,
            by_agent: entry.by_agent
          }
        end)
    }
  end

  @spec summarize_result(Run.Result.t()) :: RunSummary.t()
  @doc false
  def summarize_result(%Run.Result{} = result) do
    %RunSummary{
      run_id: result.run_id,
      task_id: result.task_id,
      state: result.state,
      reason: result.reason,
      passed: result.state == :done,
      agent_diff_size: result.agent_diff_size,
      reviewer_diff_size: result.reviewer_diff_size,
      worktree_path: result.worktree_path,
      review: summarize_review(result.review)
    }
  end

  # The review summary carries the reviewer AI's full verdict artifact — the
  # decision, its prose report, and its implementer KPI ratings. The raw agent
  # transcript stays on the %Run.Result{}/LogRecord for callers that need it.
  @spec summarize_review(Review.t() | nil) :: map() | nil
  defp summarize_review(nil), do: nil

  defp summarize_review(%Review{} = review) do
    %{
      verdict: review.verdict,
      report: review.report,
      ratings: review.ratings,
      checks: review.checks,
      concerns: review.concerns,
      review_warning: Review.warning?(review)
    }
  end

  # Summarizers for the macro-generated run-observation tools. Each projects a
  # Harness.Run payload into a JSON-safe map (no structs, no tuples).
  @spec summarize_status(Status.t()) :: map()
  @doc false
  def summarize_status(%Status{} = status) do
    %{
      run_id: status.run_id,
      task_id: status.task_id,
      project_name: status.project_name,
      dispatch_decision: status.dispatch_decision,
      state: status.state,
      worktree_path: status.worktree_path,
      agent_os_pid: status.agent_os_pid,
      agent_kind: status.agent_kind,
      review_verdict: status.review_verdict,
      reason: status.reason
    }
  end

  @spec compact_run_summary(map()) :: AwaitRunsSummary.t()
  @doc false
  def compact_run_summary(%{run_id: run_id, state: state} = summary) do
    AwaitRunsSummary.new(
      run_id,
      state,
      Map.get(summary, :reason),
      Map.get(summary, :review_verdict)
    )
  end

  @spec timeout_unfinished_run(map()) :: map()
  @doc false
  def timeout_unfinished_run(%{state: state} = summary) when state in [:done, :failed, :not_found], do: summary

  @doc false
  def timeout_unfinished_run(%{run_id: run_id, review_verdict: review_verdict}) do
    AwaitRunsSummary.new(run_id, :timed_out, :await_timeout, review_verdict)
  end

  @spec not_found_summary(String.t()) :: AwaitRunsSummary.t()
  @doc false
  def not_found_summary(run_id) do
    AwaitRunsSummary.new(run_id, :not_found, :not_found, nil)
  end

  @spec summarize_oban_job_status(Job.t()) :: map()
  @doc false
  def summarize_oban_job_status(%Job{} = job) do
    args = job.args || %{}

    %{
      run_id: fetch_arg(args, :run_id),
      task_id: fetch_arg(args, :item_id),
      project_name: fetch_arg(args, :project_name),
      dispatch_decision: fetch_arg(args, :dispatch_decision),
      state: :dispatched,
      worktree_path: nil,
      agent_os_pid: nil,
      agent_kind: nil,
      review_verdict: nil,
      reason: {:oban_job, job.state},
      oban_job_id: job.id,
      oban_state: job.state,
      queue: job.queue
    }
  end

  @spec fetch_arg(map(), atom()) :: term()
  defp fetch_arg(args, key) when is_map(args), do: Map.get(args, Atom.to_string(key), Map.get(args, key))

  @spec summarize_transcript(%{buffer: binary(), seq: non_neg_integer()}) :: map()
  @doc false
  def summarize_transcript(%{buffer: buffer, seq: seq}), do: %{transcript: buffer, seq: seq}

  @spec summarize_transcript_events(TranscriptSnapshot.t()) :: map()
  @doc false
  def summarize_transcript_events(%TranscriptSnapshot{events: events, agent_kind: agent_kind, seq: seq}) do
    %{events: Enum.map(events, &event_to_map/1), agent_kind: agent_kind, seq: seq}
  end

  # Parser events are {type, payload} tuples — not JSON-encodable. Flatten each
  # to its payload map tagged with the :type so the whole tool result serializes.
  @spec event_to_map({atom(), map()}) :: map()
  defp event_to_map({type, payload}) when is_map(payload), do: Map.put(payload, :type, type)

  @spec timeout_summary(String.t(), pos_integer()) :: map()
  @doc false
  def timeout_summary(run_id, timeout_ms) do
    %{
      run_id: run_id,
      state: :timed_out,
      reason: :await_timeout,
      passed: false,
      timeout_ms: timeout_ms,
      note:
        "The await budget elapsed before the run settled. The run was NOT cancelled and keeps going; observe it later via run_id (Harness.Run.status/1 or the recorded run records) or cancel it with Harness.Run.cancel/1."
    }
  end

  @spec summarize_comparison(Comparison.t()) :: map()
  @doc false
  def summarize_comparison(%Comparison{} = comparison) do
    %{
      batch_id: comparison.batch_id,
      task_id: comparison.task_id,
      total: comparison.total,
      max_concurrency: comparison.max_concurrency,
      entries: Enum.map(comparison.entries, &summarize_entry/1)
    }
  end

  @spec summarize_verdict_detail(LogRecord.t()) :: map()
  @doc false
  def summarize_verdict_detail(%LogRecord{} = record) do
    %{
      run_id: record.run_id,
      task_id: record.task_id,
      verdict: record.verdict,
      report: record.review_report,
      dispatch_decision: record.dispatch_decision,
      ratings: AgentKPI.record_ratings(record),
      checks: record.review_checks,
      concerns: record.review_concerns,
      proposed_tasks: record.review_proposed_tasks,
      review_warning: record.review_warning?
    }
  end

  # Project one adapter's A/B metrics into a JSON-safe map: the module to a
  # readable name, the token usage struct to a plain map, the run reason through
  # jsonable/1 (a crash reason can be a tagged tuple).
  @spec summarize_entry(Entry.t()) :: map()
  defp summarize_entry(%Entry{} = entry) do
    %{
      adapter: inspect(entry.adapter),
      run_id: entry.run_id,
      state: entry.state,
      reason: jsonable(entry.reason),
      verdict: entry.verdict,
      reviewer_diff_size: entry.reviewer_diff_size,
      duration_ms: entry.duration_ms,
      agent_diff_size: entry.agent_diff_size,
      token_usage: Map.from_struct(entry.token_usage)
    }
  end

  # Pass scalars through; inspect anything else (e.g. a {:run_crashed, _} reason)
  # so the comparison summary stays JSON-encodable. nil is an atom, so it passes.
  @spec jsonable(term()) :: term()
  defp jsonable(term) when is_atom(term) or is_binary(term) or is_number(term), do: term

  defp jsonable(term), do: inspect(term)

  # Projects a parked decision into a JSON-safe map: the adapter module to a
  # readable name, the parked_at timestamp to ISO8601.
  @spec summarize_pending(PendingDispatch.t()) :: map()
  @doc false
  def summarize_pending(%PendingDispatch{} = record) do
    %{
      id: record.id,
      project_name: record.project_name,
      task_id: record.task_id,
      adapter: inspect(record.adapter),
      dispatch_decision: Keyword.get(record.opts, :dispatch_decision),
      requested_model: Keyword.get(record.opts, :requested_model),
      parked_at: DateTime.to_iso8601(record.parked_at)
    }
  end
end
