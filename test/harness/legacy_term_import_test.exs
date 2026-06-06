defmodule Harness.LegacyTermImportTest do
  use Harness.DataCase, async: false

  alias Harness.AgentAdapter.Claude
  alias Harness.Batch.Result, as: BatchResult
  alias Harness.CapabilityScore.Legacy, as: CapabilityScore
  alias Harness.Chat.Store
  alias Harness.LegacyTermImport
  alias Harness.Repo
  alias Harness.ResultStore
  alias Harness.ResultStore.Postgres, as: PostgresStore
  alias Harness.ResultStore.Schema.BatchResult, as: BatchResultSchema
  alias Harness.ResultStore.Schema.CapabilityScore, as: CapabilityScoreSchema
  alias Harness.ResultStore.Schema.RunRecord, as: RunRecordSchema
  alias Harness.Run.LogRecord
  alias Harness.TermCodec

  @moduletag :integration

  setup do
    Repo.delete_all(RunRecordSchema)
    Repo.delete_all(BatchResultSchema)
    Repo.delete_all(CapabilityScoreSchema)

    root = Path.join(System.tmp_dir!(), "harness_legacy_import_#{System.unique_integer([:positive])}")
    results_root = Path.join(root, "results")
    chats_root = Path.join(root, "chats")

    {:ok, results_root: results_root, chats_root: chats_root}
  end

  test "imports legacy result and chat term files into Postgres", ctx do
    write_term(Path.join([ctx.results_root, "runs", encoded("legacy-run") <> ".term"]), log_record("legacy-run"))
    write_term(Path.join([ctx.results_root, "batches", encoded("legacy-batch") <> ".term"]), batch_result("legacy-batch"))

    write_term(
      Path.join([ctx.results_root, "capability_scores", encoded_score(:codex, :otp, "legacy-v1") <> ".term"]),
      capability_score()
    )

    chat_updated_at = ~U[2026-06-01 12:00:00Z]

    write_term(Path.join([ctx.chats_root, encoded("legacy-chat") <> ".term"]), %{
      session_id: "legacy-chat",
      messages: [%{role: :user, content: "preserve me"}],
      updated_at: chat_updated_at
    })

    assert %{
             runs_imported: 1,
             batches_imported: 1,
             capability_scores_imported: 1,
             chats_imported: 1
           } =
             LegacyTermImport.import_all(
               results_root: ctx.results_root,
               chats_root: ctx.chats_root,
               repo: Repo
             )

    pg = {PostgresStore, repo: Repo}
    assert {:ok, [%{run_id: "legacy-run"}]} = ResultStore.list_run_records(pg, run_id: "legacy-run")
    assert {:ok, %BatchResult{batch_id: "legacy-batch"}} = ResultStore.load_batch("legacy-batch", pg)
    assert {:ok, %CapabilityScore{agent: :codex}} = ResultStore.get_capability_score(:codex, :otp, "legacy-v1", pg)

    assert {:ok, chat} = Store.Postgres.load("legacy-chat", repo: Repo)
    assert chat.messages == [%{role: :user, content: "preserve me"}]
    assert DateTime.compare(chat.updated_at, chat_updated_at) == :eq
  end

  defp write_term(path, term) do
    assert :ok = TermCodec.write_file(path, term)
  end

  defp encoded(value), do: Base.url_encode64(value, padding: false)

  defp encoded_score(agent, domain, corpus_version) do
    {agent, domain, corpus_version}
    |> :erlang.term_to_binary()
    |> Base.url_encode64(padding: false)
  end

  defp log_record(run_id) do
    %LogRecord{
      batch_id: "legacy-batch",
      run_id: run_id,
      task_id: "legacy-task",
      adapter: Claude,
      agent: :codex,
      state: :done,
      reason: :approved,
      duration_ms: 1,
      review_iterations: 0,
      verdict: :approve
    }
  end

  defp batch_result(batch_id) do
    %BatchResult{batch_id: batch_id, total: 0, max_concurrency: 1, results: []}
  end

  defp capability_score do
    %CapabilityScore{
      agent: :codex,
      domain: :otp,
      corpus_version: "legacy-v1",
      scored_at: ~U[2026-06-01 12:00:00Z],
      run_count: 1,
      success_rate: 1.0,
      mean_reviewer_diff_size: 0.0,
      cost_to_green: 1.0,
      mean_ratings: %{},
      composite_score: 800.0,
      raw_metrics: []
    }
  end
end
