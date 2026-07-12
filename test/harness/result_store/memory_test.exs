defmodule Harness.ResultStore.MemoryTest.FailingStore do
  @moduledoc false

  @behaviour Harness.ResultStore

  alias Harness.Batch.Result, as: BatchResult
  alias Harness.Run.LogRecord

  @impl Harness.ResultStore
  @spec record_run(LogRecord.t(), keyword()) :: {:error, :boom}
  def record_run(%LogRecord{}, _opts), do: {:error, :boom}

  @impl Harness.ResultStore
  @spec save_batch(BatchResult.t(), keyword()) :: {:error, :boom}
  def save_batch(%BatchResult{}, _opts), do: {:error, :boom}

  @impl Harness.ResultStore
  @spec load_batch(String.t(), keyword()) :: {:error, :boom}
  def load_batch(_batch_id, _opts), do: {:error, :boom}

  @impl Harness.ResultStore
  @spec list_run_records(Harness.ResultStore.filters(), keyword()) :: {:error, :boom}
  def list_run_records(_filters, _opts), do: {:error, :boom}

  @impl Harness.ResultStore
  @spec delete_run(String.t(), keyword()) :: {:error, :boom}
  def delete_run(_run_id, _opts), do: {:error, :boom}

  @impl Harness.ResultStore
  @spec mark_landed(String.t(), String.t(), keyword()) :: {:error, :boom}
  def mark_landed(_run_id, _sha, _opts), do: {:error, :boom}

  @impl Harness.ResultStore
  @spec aggregate_by_agent(keyword(), keyword()) :: {:error, :boom}
  def aggregate_by_agent(_query_opts, _opts), do: {:error, :boom}

  @impl Harness.ResultStore
  @spec aggregate_reviewer_reliability(keyword(), keyword()) :: {:error, :boom}
  def aggregate_reviewer_reliability(_query_opts, _opts), do: {:error, :boom}

  @impl Harness.ResultStore
  @spec aggregate_by_facet(keyword(), keyword()) :: {:error, :boom}
  def aggregate_by_facet(_query_opts, _opts), do: {:error, :boom}
end

defmodule Harness.ResultStore.MemoryTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Claude
  alias Harness.AgentKPI
  alias Harness.Batch.Result, as: BatchResult
  alias Harness.CapabilityScore
  alias Harness.GitFixture
  alias Harness.Project
  alias Harness.ResultStore
  alias Harness.ResultStore.Memory, as: Store
  alias Harness.ResultStore.MemoryTest.FailingStore
  alias Harness.ResultStoreContract

  setup do
    scope = "memory-#{System.unique_integer([:positive])}"
    on_exit(fn -> Store.reset(scope: scope) end)
    {:ok, store: {Store, scope: scope}}
  end

  describe "ResultStore contract" do
    test "passes the shared CRUD contract", %{store: store} do
      assert :ok = ResultStoreContract.assert_crud_roundtrips(store)
    end

    test "roundtrips complex fields", %{store: store} do
      assert :ok = ResultStoreContract.assert_complex_fields(store)
    end

    test "delete_run removes one record idempotently", %{store: store} do
      assert :ok = ResultStoreContract.assert_delete_run(store)
    end

    test "same-run_id upsert preserves settled evidence", %{store: store} do
      assert :ok = ResultStoreContract.assert_same_run_id_upsert_preserves_settled_evidence(store)
    end

    test "task_id and landed_sha filters scope results", %{store: store} do
      assert :ok = ResultStoreContract.assert_scoped_filters(store)
    end
  end

  test "aggregate_reviewer_reliability matches AgentKPI over the in-memory records", %{store: store} do
    records = [
      ResultStoreContract.log_record(
        run_id: "mem-rv1",
        verdict: :reject,
        reviewer_adapter: Claude
      ),
      ResultStoreContract.log_record(
        run_id: "mem-rv2",
        verdict: nil,
        reason: {:review_stuck, "no artifact"},
        reviewer_adapter: Claude
      )
    ]

    for record <- records, do: assert(:ok = ResultStore.record_run(record, store))

    assert {:ok, ledger} = ResultStore.aggregate_reviewer_reliability(store)
    assert ledger == AgentKPI.aggregate_reviewer_rejections(records)
  end

  test "aggregate_by_facet matches CapabilityScore.build_scout_context/1", %{store: store} do
    records = [
      ResultStoreContract.log_record(
        run_id: "mem-f1",
        agent: :codex,
        verdict: :approve,
        review_facets: %{"surface" => "otp"}
      ),
      ResultStoreContract.log_record(run_id: "mem-f2", agent: :grok, verdict: :reject, review_facets: %{})
    ]

    for record <- records, do: assert(:ok = ResultStore.record_run(record, store))

    expected =
      records
      |> CapabilityScore.build_scout_context()
      |> Enum.map(fn %{facet: facet, by_agent: agents} -> %{facet: facet, agents: agents} end)

    assert {:ok, groups} = ResultStore.aggregate_by_facet(store)

    assert Enum.sort_by(groups, &Jason.encode!(Map.get(&1, :facet, %{}))) ==
             Enum.sort_by(expected, &Jason.encode!(Map.get(&1, :facet, %{})))
  end

  test "aggregate_by_agent matches AgentKPI over the in-memory records", %{store: store} do
    records = [
      ResultStoreContract.log_record(run_id: "mem-a", agent: :codex, verdict: :approve),
      ResultStoreContract.log_record(run_id: "mem-b", agent: :codex, verdict: :reject)
    ]

    for record <- records, do: assert(:ok = ResultStore.record_run(record, store))

    assert {:ok, ledger} = ResultStore.aggregate_by_agent(store)
    assert ledger == AgentKPI.aggregate(records)
  end

  test "aggregate_recovery_facts matches AgentKPI over persisted records", %{store: store} do
    records = [
      ResultStoreContract.log_record(
        run_id: "mem-recovery-repaired",
        task_id: "42",
        agent: :codex,
        recovery_attempts: 1,
        recovery_outcome: :repaired,
        recovery_repaired: "moved leaked checkout file",
        recovery_token_usage: %Harness.TokenUsage{input: 20, output: 10, total: 30}
      ),
      ResultStoreContract.log_record(
        run_id: "mem-recovery-dead",
        task_id: "43",
        agent: :claude,
        recovery_attempts: 1,
        recovery_outcome: :dead,
        recovery_token_usage: %Harness.TokenUsage{input: 5, output: 5, total: 10}
      )
    ]

    for record <- records, do: assert(:ok = ResultStore.record_run(record, store))

    assert {:ok, facts} = ResultStore.aggregate_recovery_facts(store)
    assert sort_recovery_runs(facts) == records |> AgentKPI.aggregate_recovery_facts() |> sort_recovery_runs()
  end

  test "aggregate_review_stuck_causes matches AgentKPI over in-memory records", %{store: store} do
    records = [
      ResultStoreContract.log_record(
        run_id: "mem-stuck-selection",
        verdict: nil,
        reason:
          {:review_stuck, "No cross-family reviewer adapter available: {:reviewer_unavailable, #{inspect(Claude)}}"},
        reviewer_adapter: nil
      ),
      ResultStoreContract.log_record(
        run_id: "mem-stuck-timeout",
        verdict: nil,
        reason: {:review_stuck, :timed_out},
        reviewer_adapter: Harness.AgentAdapter.Codex
      ),
      ResultStoreContract.log_record(run_id: "mem-approved", verdict: :approve, reason: :approved)
    ]

    for record <- records, do: assert(:ok = ResultStore.record_run(record, store))

    assert {:ok, causes} = ResultStore.aggregate_review_stuck_causes(store)
    assert causes == AgentKPI.aggregate_review_stuck_causes(records)
  end

  test "disabled stores return no-op values for write and read helpers" do
    record = ResultStoreContract.log_record(run_id: "disabled-record")
    batch = %BatchResult{batch_id: "disabled-batch", total: 0, max_concurrency: 1, results: []}

    for disabled <- [false, nil] do
      assert :ok = ResultStore.record_run(record, disabled)
      assert :ok = ResultStore.save_batch(batch, disabled)
      assert {:error, :disabled} = ResultStore.load_batch("disabled-batch", disabled)
      assert {:ok, []} = ResultStore.list_run_records(disabled, run_id: "disabled-record")
      assert :ok = ResultStore.delete_run("disabled-record", disabled)
      assert :ok = ResultStore.mark_landed("disabled-record", "abc1234", disabled)
      assert {:ok, %{}} = ResultStore.aggregate_by_agent(disabled)
      assert {:ok, %{}} = ResultStore.aggregate_reviewer_reliability(disabled)
      assert {:ok, []} = ResultStore.aggregate_by_facet(disabled)
      assert {:ok, %{}} = ResultStore.aggregate_review_stuck_causes(disabled)
      assert {:ok, facts} = ResultStore.aggregate_recovery_facts(disabled)
      assert facts == AgentKPI.aggregate_recovery_facts([])
      assert {:ok, ceremony} = ResultStore.aggregate_ceremony_cost([], disabled)
      assert ceremony == AgentKPI.aggregate_ceremony_cost([])
    end
  end

  test "default configured sentinel dispatches to the configured store", %{store: store} do
    prior = Application.get_env(:harness, :result_store)
    Application.put_env(:harness, :result_store, store)
    on_exit(fn -> restore(:result_store, prior) end)

    batch = %BatchResult{batch_id: "sentinel-batch", total: 0, max_concurrency: 1, results: []}

    assert :ok = ResultStore.save_batch(batch)
    assert {:ok, %BatchResult{batch_id: "sentinel-batch"}} = ResultStore.load_batch("sentinel-batch")
    assert {:ok, %{}} = ResultStore.aggregate_by_agent()
    assert {:ok, %{}} = ResultStore.aggregate_reviewer_reliability()
    assert {:ok, []} = ResultStore.aggregate_by_facet()
    assert {:ok, %{}} = ResultStore.aggregate_review_stuck_causes()
    assert {:ok, facts} = ResultStore.aggregate_recovery_facts()
    assert facts == AgentKPI.aggregate_recovery_facts([])
    assert {:ok, ceremony} = ResultStore.aggregate_ceremony_cost()
    assert ceremony == AgentKPI.aggregate_ceremony_cost([])
  end

  test "public defaults dispatch through configured store", %{store: store} do
    prior = Application.get_env(:harness, :result_store)
    Application.put_env(:harness, :result_store, store)
    on_exit(fn -> restore(:result_store, prior) end)

    record = ResultStoreContract.log_record(run_id: "configured-defaults")

    assert :ok = ResultStore.record_run(record)
    assert {:ok, [%{run_id: "configured-defaults"}]} = ResultStore.list_run_records()
    assert :ok = ResultStore.mark_landed("configured-defaults", "abc1234")
    assert {:ok, [%{landed_sha: "abc1234"}]} = ResultStore.list_run_records(run_id: "configured-defaults")
    assert :ok = ResultStore.delete_run("configured-defaults")
    assert {:ok, []} = ResultStore.list_run_records(run_id: "configured-defaults")
  end

  test "sentinel aggregate calls re-read configured store", %{store: store} do
    prior = Application.get_env(:harness, :result_store)
    Application.put_env(:harness, :result_store, store)
    on_exit(fn -> restore(:result_store, prior) end)

    assert {:ok, %{}} = ResultStore.aggregate_by_agent(:configured_result_store)
    assert {:ok, %{}} = ResultStore.aggregate_reviewer_reliability(:configured_result_store)
    assert {:ok, []} = ResultStore.aggregate_by_facet(:configured_result_store)
    assert {:ok, %{}} = ResultStore.aggregate_review_stuck_causes(:configured_result_store)
    assert {:ok, facts} = ResultStore.aggregate_recovery_facts(:configured_result_store)
    assert facts == AgentKPI.aggregate_recovery_facts([])
    assert {:ok, ceremony} = ResultStore.aggregate_ceremony_cost([], :configured_result_store)
    assert ceremony == AgentKPI.aggregate_ceremony_cost([])
  end

  test "derived aggregates return list errors unchanged" do
    assert {:error, :boom} = ResultStore.aggregate_review_stuck_causes(FailingStore)
    assert {:error, :boom} = ResultStore.aggregate_recovery_facts(FailingStore)
    assert {:error, :boom} = ResultStore.aggregate_ceremony_cost([], FailingStore)
  end

  describe "reconcile_landed_sha/4" do
    test "fills landed_sha when shipped_in is an ancestor of origin target", %{store: store} do
      %{repo: repo} = GitFixture.init_with_origin()
      project = local_project(repo)
      sha = commit_and_push(repo, "landed.txt", "landed\n")
      run_id = "reconcile-ancestor"

      assert :ok = ResultStore.record_run(ResultStoreContract.log_record(run_id: run_id), store)

      assert {:ok, ^sha} = ResultStore.reconcile_landed_sha(run_id, sha, project, store)
      assert {:ok, [%{landed_sha: ^sha}]} = ResultStore.list_run_records(store, run_id: run_id)
    end

    test "fills landed_sha from the run branch when shipped_in is absent", %{store: store} do
      %{repo: repo} = GitFixture.init_with_origin()
      project = local_project(repo)
      run_id = "reconcile-branch"
      branch = "harness/#{run_id}"

      GitFixture.git!(repo, ["checkout", "-q", "-b", branch])
      File.write!(Path.join(repo, "branch-landed.txt"), "landed\n")
      GitFixture.git!(repo, ["add", "."])
      GitFixture.git!(repo, ["commit", "-q", "-m", "branch landed"])
      sha = repo |> GitFixture.git!(["rev-parse", "HEAD"]) |> String.trim()
      GitFixture.git!(repo, ["checkout", "-q", "main"])
      GitFixture.git!(repo, ["merge", "--ff-only", "-q", branch])
      GitFixture.git!(repo, ["push", "-q", "origin", "main"])

      assert :ok = ResultStore.record_run(ResultStoreContract.log_record(run_id: run_id), store)

      assert {:ok, ^sha} = ResultStore.reconcile_landed_sha(run_id, nil, project, store)
      assert {:ok, [%{landed_sha: ^sha}]} = ResultStore.list_run_records(store, run_id: run_id)
    end

    test "leaves landed_sha nil when shipped_in is not on origin target", %{store: store} do
      %{repo: repo} = GitFixture.init_with_origin()
      project = local_project(repo)
      sha = commit_without_push(repo, "unlanded.txt", "not landed\n")
      run_id = "reconcile-unlanded"

      assert :ok = ResultStore.record_run(ResultStoreContract.log_record(run_id: run_id), store)

      assert :unchanged = ResultStore.reconcile_landed_sha(run_id, sha, project, store)
      assert {:ok, [%{landed_sha: nil}]} = ResultStore.list_run_records(store, run_id: run_id)
    end
  end

  test "repo_enabled false selects ephemeral memory when no explicit override" do
    prior_repo_enabled = Application.get_env(:harness, :repo_enabled)
    prior_result_store = Application.get_env(:harness, :result_store)

    Application.put_env(:harness, :repo_enabled, false)
    Application.delete_env(:harness, :result_store)

    on_exit(fn ->
      restore(:repo_enabled, prior_repo_enabled)
      restore(:result_store, prior_result_store)
    end)

    assert {Store, []} = ResultStore.configured()
  end

  test "ephemeral memory does not survive a reset", %{store: store} do
    assert :ok = ResultStore.record_run(ResultStoreContract.log_record(run_id: "gone-after-restart"), store)
    assert {:ok, [_]} = ResultStore.list_run_records(store, run_id: "gone-after-restart")

    assert :ok = Store.reset(elem(store, 1))
    assert {:ok, []} = ResultStore.list_run_records(store, run_id: "gone-after-restart")
  end

  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)

  defp sort_recovery_runs(facts) do
    Map.update!(facts, :per_run, &Enum.sort_by(&1, fn row -> row.run_id end))
  end

  @spec local_project(String.t()) :: Project.t()
  defp local_project(repo) do
    %Project{name: "reconcile", source: {:local, repo}, roadmap_path: repo, languages: [:elixir], target_branch: "main"}
  end

  @spec commit_and_push(String.t(), String.t(), String.t()) :: String.t()
  defp commit_and_push(repo, file, contents) do
    sha = commit_without_push(repo, file, contents)
    GitFixture.git!(repo, ["push", "-q", "origin", "main"])
    sha
  end

  @spec commit_without_push(String.t(), String.t(), String.t()) :: String.t()
  defp commit_without_push(repo, file, contents) do
    File.write!(Path.join(repo, file), contents)
    GitFixture.git!(repo, ["add", "."])
    GitFixture.git!(repo, ["commit", "-q", "-m", "test commit"])
    repo |> GitFixture.git!(["rev-parse", "HEAD"]) |> String.trim()
  end
end
