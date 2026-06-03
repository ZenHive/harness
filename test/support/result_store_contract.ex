defmodule Harness.ResultStoreContract do
  @moduledoc """
  Shared contract assertions for any Harness.ResultStore backend (Task 137).

  Extracted from the original FileTest CRUD roundtrips so both File and
  Postgres (and future backends) exercise the identical behaviour.
  """

  import ExUnit.Assertions

  alias Harness.AgentAdapter.Claude
  alias Harness.AgentAdapter.Codex
  alias Harness.Batch.Result, as: BatchResult
  alias Harness.ResultStore
  alias Harness.Run.LogRecord
  alias Harness.TokenUsage

  @spec log_record(keyword()) :: LogRecord.t()
  def log_record(overrides \\ []) do
    struct(
      %LogRecord{
        batch_id: "batch-test",
        run_id: "run-abc",
        task_id: "task-73",
        adapter: Claude,
        state: :done,
        reason: :approved,
        verdict: :approve,
        duration_ms: 1234,
        review_iterations: 0
      },
      overrides
    )
  end

  @doc "Run the basic CRUD + filter roundtrips against the given store (module or {mod, opts})."
  @spec assert_crud_roundtrips(ResultStore.store()) :: :ok
  def assert_crud_roundtrips(store) do
    # record + list filter
    record = %LogRecord{
      batch_id: "b1",
      run_id: "r1",
      task_id: "t1",
      adapter: Claude,
      state: :done,
      reason: :approved,
      verdict: :approve,
      duration_ms: 42,
      review_iterations: 0
    }

    assert :ok = ResultStore.record_run(record, store)

    assert {:ok, [retrieved]} = ResultStore.list_run_records(store, batch_id: "b1")
    assert retrieved.run_id == "r1"
    assert retrieved.state == :done
    assert retrieved.verdict == :approve
    assert retrieved.domains == []

    # domains roundtrip (added post-Task 116)
    rec_d = log_record(run_id: "r-domains", domains: [:otp, :oban])
    assert :ok = ResultStore.record_run(rec_d, store)
    assert {:ok, [rd]} = ResultStore.list_run_records(store, run_id: "r-domains")
    assert rd.domains == [:otp, :oban]

    # non-match
    assert {:ok, []} = ResultStore.list_run_records(store, batch_id: "nope")

    # batch
    br = %BatchResult{batch_id: "batch-crud", total: 0, max_concurrency: 1, results: []}
    assert :ok = ResultStore.save_batch(br, store)
    assert {:ok, loaded} = ResultStore.load_batch("batch-crud", store)
    assert loaded.batch_id == "batch-crud"

    :ok
  end

  @doc "Roundtrip a record with tuple reason (e.g. {:agent_spawn_failed, :enoent}) and non-UTF8 agent_output."
  @spec assert_complex_fields(ResultStore.store()) :: :ok
  def assert_complex_fields(store) do
    non_utf8 = <<0, 255, 128, 42, 0>>
    reason = {:agent_spawn_failed, :enoent}

    rec =
      log_record(
        run_id: "r-complex",
        state: :failed,
        reason: reason,
        verdict: nil,
        agent_output: non_utf8
      )

    assert :ok = ResultStore.record_run(rec, store)

    assert {:ok, [retrieved]} = ResultStore.list_run_records(store, run_id: "r-complex")
    assert retrieved.reason == reason
    assert retrieved.agent_output == non_utf8
    assert retrieved.verdict == nil

    # struct identity, string map keys, and list-of-maps roundtrip
    # (token_usage / review_ratings / composed_inputs)
    composed_input = %{
      executable: "claude",
      argv: ["-p", "do the task"],
      rule_channel: :system_prompt_file,
      prompt: "do the task",
      session: nil,
      rule_files: [],
      attempt: 0,
      phase: :initial
    }

    rec_full =
      log_record(
        run_id: "r-full",
        token_usage: %TokenUsage{input: 100, output: 50, total: 150},
        composed_inputs: [composed_input],
        agent_outcome_kind: :exited,
        reviewer_diff_size: 12,
        review_iterations: 1,
        reviewer_adapter: Codex,
        review_report: "fixed a credo nit inline; approving",
        review_ratings: %{"performance" => 8, "code_quality" => 7}
      )

    assert :ok = ResultStore.record_run(rec_full, store)

    assert {:ok, [rf]} = ResultStore.list_run_records(store, run_id: "r-full")
    assert rf.token_usage == %TokenUsage{input: 100, output: 50, total: 150}
    assert rf.composed_inputs == [composed_input]
    assert rf.agent_outcome_kind == :exited
    assert rf.reviewer_diff_size == 12
    assert rf.review_iterations == 1
    assert rf.reviewer_adapter == Codex
    assert rf.review_report == "fixed a credo nit inline; approving"
    assert rf.review_ratings == %{"performance" => 8, "code_quality" => 7}

    # tuple agent_outcome_kind roundtrip — regression for the
    # {:timed_out, :idle} FunctionClauseError that crashed Postgres.record_run
    # (string column needs a kind codec, not Atom.to_string)
    for kind <- [{:timed_out, :idle}, {:timed_out, :total}, {:error, :port_closed}] do
      run_id = "r-kind-#{:erlang.phash2(kind)}"

      rec_kind = log_record(run_id: run_id, agent_outcome_kind: kind)
      assert :ok = ResultStore.record_run(rec_kind, store)

      assert {:ok, [rk]} = ResultStore.list_run_records(store, run_id: run_id)
      assert rk.agent_outcome_kind == kind
    end

    :ok
  end
end
