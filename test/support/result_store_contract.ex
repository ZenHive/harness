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
    assert retrieved.landed_sha == nil
    assert retrieved.domains == []
    # a record that omits the reviewer rubric reads back with empty-map defaults,
    # never nil — missing-block tolerance through the store layer (Task 224).
    assert retrieved.review_facets == %{}
    assert retrieved.review_skills == %{}
    assert retrieved.review_checks == %{}
    assert retrieved.review_concerns == []
    assert retrieved.review_proposed_tasks == []
    assert retrieved.review_warning? == false
    assert retrieved.cold_check == nil
    assert retrieved.approved_then_found_red == %{}

    # domains roundtrip (added post-Task 116)
    rec_d = log_record(run_id: "r-domains", domains: [:otp, :oban])
    assert :ok = ResultStore.record_run(rec_d, store)
    assert {:ok, [rd]} = ResultStore.list_run_records(store, run_id: "r-domains")
    assert rd.domains == [:otp, :oban]

    rec_landed = log_record(run_id: "r-landed", landed_sha: "abc1234ff")
    assert :ok = ResultStore.record_run(rec_landed, store)
    assert {:ok, [rl]} = ResultStore.list_run_records(store, run_id: "r-landed")
    assert rl.landed_sha == "abc1234ff"

    rec_marked = log_record(run_id: "r-marked")
    assert :ok = ResultStore.record_run(rec_marked, store)
    assert :ok = ResultStore.mark_landed("r-marked", "def5678aa", store)
    assert {:ok, [rm]} = ResultStore.list_run_records(store, run_id: "r-marked")
    assert rm.landed_sha == "def5678aa"

    # non-match
    assert {:ok, []} = ResultStore.list_run_records(store, batch_id: "nope")

    # batch
    br = %BatchResult{batch_id: "batch-crud", total: 0, max_concurrency: 1, results: []}
    assert :ok = ResultStore.save_batch(br, store)
    assert {:ok, loaded} = ResultStore.load_batch("batch-crud", store)
    assert loaded.batch_id == "batch-crud"

    :ok
  end

  @doc "Delete a persisted run record by id; deletion is idempotent and scoped to the one run_id."
  @spec assert_delete_run(ResultStore.store()) :: :ok
  def assert_delete_run(store) do
    keep = log_record(run_id: "r-keep", batch_id: "b-del")
    drop = log_record(run_id: "r-drop", batch_id: "b-del")
    assert :ok = ResultStore.record_run(keep, store)
    assert :ok = ResultStore.record_run(drop, store)

    # both present
    assert {:ok, [_, _]} = ResultStore.list_run_records(store, batch_id: "b-del")

    # delete one — returns :ok, removes only that row
    assert :ok = ResultStore.delete_run("r-drop", store)
    assert {:ok, []} = ResultStore.list_run_records(store, run_id: "r-drop")
    assert {:ok, [survivor]} = ResultStore.list_run_records(store, run_id: "r-keep")
    assert survivor.run_id == "r-keep"

    # idempotent — deleting an absent record is still :ok
    assert :ok = ResultStore.delete_run("r-drop", store)
    assert :ok = ResultStore.delete_run("never-existed", store)

    :ok
  end

  @doc "Same-run_id upserts preserve settled evidence while latest bookkeeping wins."
  @spec assert_same_run_id_upsert_preserves_settled_evidence(ResultStore.store()) :: :ok
  def assert_same_run_id_upsert_preserves_settled_evidence(store) do
    rich =
      log_record(
        run_id: "r-upsert",
        state: :failed,
        reason: {:review_rejected, "not salvageable"},
        duration_ms: 4321,
        verdict: :reject,
        landed_sha: "abc1234ff",
        agent_output: "rich transcript",
        agent_outcome_kind: :exited,
        agent_exit_status: 0,
        agent_diff_size: 12,
        reviewer_diff_size: 30,
        review_iterations: 1,
        reviewer_reprompt_count: 1,
        reviewer_rotation_count: 2,
        reviewer_adapter: Claude,
        reviewer_model: "review-model",
        review_report: "not salvageable",
        review_facets: %{"surface" => "otp"},
        review_skills: %{"otp" => %{"score" => 8}},
        review_checks: %{"mix check.dispatch" => %{"passed" => false}},
        review_concerns: [%{"kind" => "dismissed_red"}],
        review_proposed_tasks: [%{"title" => "Add handoff trace"}],
        review_warning?: true,
        review_ratings: %{"code_quality" => 2},
        reviewer_outcome_kind: :exited,
        reviewer_exit_status: 0,
        reviewer_output: "reviewer transcript: checks pass, no verdict written",
        recovery_attempts: 1,
        recovery_outcome: :dead,
        recovery_repaired: "documented unrecoverable checkout leak",
        recovery_token_usage: %TokenUsage{input: 20, output: 10, total: 30},
        cold_check: %{"passed" => false, "command" => "mix precommit"},
        approved_then_found_red: %{"cold_check" => %{"passed" => false}}
      )

    assert :ok = ResultStore.record_run(rich, store)

    sparse =
      log_record(
        run_id: "r-upsert",
        state: :done,
        reason: :approved,
        duration_ms: 5,
        verdict: nil,
        review_ratings: %{}
      )

    assert :ok = ResultStore.record_run(sparse, store)

    assert {:ok, [rec]} = ResultStore.list_run_records(store, run_id: "r-upsert")

    assert rec.state == :done
    assert rec.reason == :approved
    assert rec.duration_ms == 5

    assert rec.verdict == :reject
    assert rec.landed_sha == "abc1234ff"
    assert rec.agent_output == "rich transcript"
    assert rec.agent_outcome_kind == :exited
    assert rec.agent_exit_status == 0
    assert rec.agent_diff_size == 12
    assert rec.reviewer_diff_size == 30
    assert rec.review_iterations == 1
    assert rec.reviewer_reprompt_count == 1
    assert rec.reviewer_rotation_count == 2
    assert rec.reviewer_adapter == Claude
    assert rec.reviewer_model == "review-model"
    assert rec.review_report == "not salvageable"
    assert rec.review_facets == %{"surface" => "otp"}
    assert rec.review_skills == %{"otp" => %{"score" => 8}}
    assert rec.review_checks == %{"mix check.dispatch" => %{"passed" => false}}
    assert rec.review_concerns == [%{"kind" => "dismissed_red"}]
    assert rec.review_proposed_tasks == [%{"title" => "Add handoff trace"}]
    assert rec.review_warning? == true
    assert rec.review_ratings == %{"code_quality" => 2}
    assert rec.reviewer_outcome_kind == :exited
    assert rec.reviewer_exit_status == 0
    assert rec.reviewer_output == "reviewer transcript: checks pass, no verdict written"
    assert rec.recovery_attempts == 1
    assert rec.recovery_outcome == :dead
    assert rec.recovery_repaired == "documented unrecoverable checkout leak"
    assert rec.recovery_token_usage == %TokenUsage{input: 20, output: 10, total: 30}
    assert rec.cold_check == %{"passed" => false, "command" => "mix precommit"}
    assert rec.approved_then_found_red == %{"cold_check" => %{"passed" => false}}

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

    # Non-UTF8 reviewer transcript exercises the :binary column / blob codec,
    # mirroring agent_output; a point lookup (run_id filter) keeps the blob.
    reviewer_non_utf8 = <<7, 254, 0, 99, 255>>

    rec_full =
      log_record(
        run_id: "r-full",
        token_usage: %TokenUsage{input: 100, output: 50, total: 150},
        composed_inputs: [composed_input],
        agent_outcome_kind: :exited,
        reviewer_diff_size: 12,
        review_iterations: 1,
        reviewer_reprompt_count: 1,
        reviewer_rotation_count: 2,
        reviewer_adapter: Codex,
        reviewer_model: "gpt-5.5-review",
        review_report: "fixed a credo nit inline; approving",
        review_facets: %{"language" => "elixir", "surface" => "otp", "archetype" => "feature"},
        review_skills: %{"otp" => %{"score" => 8, "note" => "clean gen_statem"}},
        review_checks: %{"mix precommit" => %{"passed" => false, "output" => "doc chunk failure"}},
        review_concerns: [%{"kind" => "dismissed_red", "mechanism" => "reproduced docs config"}],
        review_warning?: true,
        review_ratings: %{"performance" => 8, "code_quality" => 7},
        reviewer_outcome_kind: :exited,
        reviewer_exit_status: 0,
        reviewer_output: reviewer_non_utf8,
        recovery_attempts: 1,
        recovery_outcome: :repaired,
        recovery_repaired: "moved leaked file",
        recovery_token_usage: %TokenUsage{input: 10, output: 5, total: 15},
        cold_check: %{"passed" => false, "command" => "mix precommit", "tail" => "cold compile failed"},
        approved_then_found_red: %{
          "reviewer_adapter" => Atom.to_string(Codex),
          "reviewer_agent" => "codex",
          "reviewer_model" => "gpt-5.5-review",
          "review_facets" => %{"surface" => "otp"},
          "domains" => ["otp"],
          "cold_check" => %{"passed" => false}
        }
      )

    assert :ok = ResultStore.record_run(rec_full, store)

    assert {:ok, [rf]} = ResultStore.list_run_records(store, run_id: "r-full")
    assert rf.token_usage == %TokenUsage{input: 100, output: 50, total: 150}
    assert rf.composed_inputs == [composed_input]
    assert rf.agent_outcome_kind == :exited
    assert rf.reviewer_diff_size == 12
    assert rf.review_iterations == 1
    assert rf.reviewer_reprompt_count == 1
    assert rf.reviewer_rotation_count == 2
    assert rf.reviewer_adapter == Codex
    assert rf.reviewer_model == "gpt-5.5-review"
    assert rf.review_report == "fixed a credo nit inline; approving"
    # facets (routing KEY) + skills (routing VALUE) round-trip verbatim, including
    # the nested {score, note} maps — free-form string keys preserved at every level.
    assert rf.review_facets == %{"language" => "elixir", "surface" => "otp", "archetype" => "feature"}
    assert rf.review_skills == %{"otp" => %{"score" => 8, "note" => "clean gen_statem"}}
    assert rf.review_checks == %{"mix precommit" => %{"passed" => false, "output" => "doc chunk failure"}}
    assert rf.review_concerns == [%{"kind" => "dismissed_red", "mechanism" => "reproduced docs config"}]
    assert rf.review_warning? == true
    assert rf.review_ratings == %{"performance" => 8, "code_quality" => 7}
    assert rf.reviewer_outcome_kind == :exited
    assert rf.reviewer_exit_status == 0
    assert rf.reviewer_output == reviewer_non_utf8
    assert rf.recovery_attempts == 1
    assert rf.recovery_outcome == :repaired
    assert rf.recovery_repaired == "moved leaked file"
    assert rf.recovery_token_usage == %TokenUsage{input: 10, output: 5, total: 15}
    assert rf.cold_check == %{"passed" => false, "command" => "mix precommit", "tail" => "cold compile failed"}

    assert rf.approved_then_found_red == %{
             "reviewer_adapter" => Atom.to_string(Codex),
             "reviewer_agent" => "codex",
             "reviewer_model" => "gpt-5.5-review",
             "review_facets" => %{"surface" => "otp"},
             "domains" => ["otp"],
             "cold_check" => %{"passed" => false}
           }

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

  @doc """
  The `:task_id` and `:landed_sha` filters must scope results to matching rows.

  Regression for the Postgres backend silently dropping `:task_id` (the recovery
  lookup `Run.Worker.recoverable_run_record/2` relies on) and `:landed_sha` (the
  post-merge `Audit.persist_cold_check/4` lookup). The Memory backend filtered
  these generically all along, so this contract — run against BOTH backends —
  catches any future divergence where one honours a filter the other ignores.
  """
  @spec assert_scoped_filters(ResultStore.store()) :: :ok
  def assert_scoped_filters(store) do
    proj = "proj-scoped"
    a1 = log_record(run_id: "r-a1", task_id: "task-A", project_name: proj)
    a2 = log_record(run_id: "r-a2", task_id: "task-A", project_name: proj)
    b1 = log_record(run_id: "r-b1", task_id: "task-B", project_name: proj)
    for rec <- [a1, a2, b1], do: assert(:ok = ResultStore.record_run(rec, store))

    # :task_id must return only the two task-A rows, never the whole project.
    assert {:ok, task_a} = ResultStore.list_run_records(store, project_name: proj, task_id: "task-A")
    assert task_a |> Enum.map(& &1.run_id) |> Enum.sort() == ["r-a1", "r-a2"]

    assert {:ok, task_b} = ResultStore.list_run_records(store, project_name: proj, task_id: "task-B")
    assert Enum.map(task_b, & &1.run_id) == ["r-b1"]

    assert {:ok, []} = ResultStore.list_run_records(store, task_id: "task-absent")

    # :landed_sha must scope to the single landed row.
    landed = log_record(run_id: "r-landed-scoped", task_id: "task-A", project_name: proj, landed_sha: "sha-9f9f")
    assert :ok = ResultStore.record_run(landed, store)

    assert {:ok, [only]} = ResultStore.list_run_records(store, project_name: proj, landed_sha: "sha-9f9f")
    assert only.run_id == "r-landed-scoped"

    assert {:ok, []} = ResultStore.list_run_records(store, landed_sha: "sha-absent")

    :ok
  end
end
