defmodule Harness.ResultStore.PostgresCodecTest do
  @moduledoc """
  Unit tests for the Postgres backend's serialization codec — the
  `LogRecord` ↔ row encoding (kind/atom/module string codecs, `$atom` /
  `$tuple` / `$list` jsonb markers, struct identity restore) — exercised
  through `record_run/2` + `list_run_records/2` with an in-process fake
  repo, so the codec is graded by the default (non-`:integration`) suite.

  The live-DB contract stays in `Harness.ResultStore.PostgresTest`
  (`:integration`). This module exists so the `{:timed_out, :idle}`
  FunctionClauseError class (a kind the codec can't encode crashing the
  calling gen_statem) is caught without a Postgres instance.
  """

  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Codex
  alias Harness.AgentKPI.TokenMeans
  alias Harness.Batch.Result, as: BatchResult
  alias Harness.ResultStore.Postgres
  alias Harness.ResultStoreContract
  alias Harness.Run.LogRecord
  alias Harness.TokenUsage

  defmodule FakeRepo do
    @moduledoc false
    # In-process row store: insert/2 applies the changeset and keeps the row;
    # all/1 returns every kept row (filters are ignored — one record per test).

    @spec insert(Ecto.Changeset.t(), keyword()) :: {:ok, struct()}
    def insert(changeset, _opts) do
      row = Ecto.Changeset.apply_action!(changeset, :insert)
      Process.put({__MODULE__, :rows}, [row | rows()])
      {:ok, row}
    end

    @spec all(Ecto.Query.t()) :: [struct()]
    def all(_query), do: rows()

    @spec get(module(), String.t()) :: struct() | nil
    def get(schema, id) do
      Enum.find(rows(), &match?(%{__struct__: ^schema, batch_id: ^id}, &1))
    end

    @spec delete_all(Ecto.Query.t()) :: {non_neg_integer(), nil}
    def delete_all(_query), do: {0, nil}

    @spec update_all(Ecto.Query.t(), keyword()) :: {non_neg_integer(), nil}
    def update_all(_query, _updates), do: {1, nil}

    @spec reset() :: :ok
    def reset do
      Process.put({__MODULE__, :rows}, [])
      :ok
    end

    @spec put_rows([map() | struct()]) :: :ok
    def put_rows(rows) when is_list(rows) do
      Process.put({__MODULE__, :rows}, rows)
      :ok
    end

    @spec rows() :: [struct()]
    defp rows, do: Process.get({__MODULE__, :rows}, [])
  end

  defmodule RaisingRepo do
    @moduledoc false
    # insert/2 raises a genuine DB *failure* (connection loss) → exercises the
    # best-effort rescue, which the narrowed `@persistence_errors` swallows.

    @spec insert(Ecto.Changeset.t(), keyword()) :: no_return()
    def insert(_changeset, _opts), do: raise(DBConnection.ConnectionError, "simulated connection loss")
  end

  describe "agent_outcome_kind codec" do
    test "tuple kinds round-trip (the {:timed_out, :idle} crash regression)" do
      for kind <- [{:timed_out, :idle}, {:timed_out, :total}, {:error, :port_closed}] do
        FakeRepo.reset()
        record = ResultStoreContract.log_record(run_id: "kind-rt", agent_outcome_kind: kind)

        assert roundtrip(record).agent_outcome_kind == kind
      end
    end

    test "bare atom kind round-trips as a plain column string (back-compat)" do
      record = ResultStoreContract.log_record(run_id: "kind-atom", agent_outcome_kind: :exited)

      assert roundtrip(record).agent_outcome_kind == :exited
    end

    test "nil kind stays nil" do
      record = ResultStoreContract.log_record(run_id: "kind-nil", agent_outcome_kind: nil)

      assert roundtrip(record).agent_outcome_kind == nil
    end
  end

  describe "jsonb term codec" do
    test "reviewer fallback counters round-trip as raw run facts" do
      record =
        ResultStoreContract.log_record(
          run_id: "reviewer-fallback-counts",
          reviewer_reprompt_count: 1,
          reviewer_rotation_count: 2
        )

      decoded = roundtrip(record)

      assert decoded.reviewer_reprompt_count == 1
      assert decoded.reviewer_rotation_count == 2
    end

    test "tuple reason round-trips via the $tuple marker" do
      reason = {:agent_spawn_failed, :enoent}

      record = ResultStoreContract.log_record(run_id: "jsonb-reason", reason: reason)

      assert roundtrip(record).reason == reason
    end

    test "reviewer rejection reason (tagged tuple with a report string) round-trips" do
      reason = {:review_rejected, "nothing salvageable"}

      record = ResultStoreContract.log_record(run_id: "jsonb-rejection", reason: reason, verdict: :reject)

      decoded = roundtrip(record)

      assert decoded.reason == reason
      assert decoded.verdict == :reject
    end

    test "token_usage struct identity is restored on read" do
      usage = %TokenUsage{input: 100, output: 50, total: 150}
      record = ResultStoreContract.log_record(run_id: "jsonb-usage", token_usage: usage)

      assert roundtrip(record).token_usage == usage
    end

    test "review_ratings outer keys stay strings; values decode" do
      ratings = %{"performance" => 8, "code_quality" => 7}
      record = ResultStoreContract.log_record(run_id: "jsonb-ratings", review_ratings: ratings)

      assert roundtrip(record).review_ratings == ratings
    end

    test "review checks, concerns, and warning flag round-trip as reviewer-written facts" do
      record =
        ResultStoreContract.log_record(
          run_id: "jsonb-review-checks",
          review_checks: %{"mix precommit" => %{"passed" => false, "output" => "red"}},
          review_concerns: [%{"kind" => "dismissed_red", "mechanism" => "reproduced config bug"}],
          review_warning?: true
        )

      decoded = roundtrip(record)

      assert decoded.review_checks == %{"mix precommit" => %{"passed" => false, "output" => "red"}}
      assert decoded.review_concerns == [%{"kind" => "dismissed_red", "mechanism" => "reproduced config bug"}]
      assert decoded.review_warning? == true
    end

    test "reviewer proposed tasks round-trip as a free-form proposal list" do
      proposals = [
        %{
          "title" => "Add event tracing",
          "body" => "Record dispatch handoffs.",
          "suggested_scores" => %{"difficulty" => 4, "benefit" => 8},
          "suggested_markers" => ["parallel"],
          "evidence" => "The reviewer could not inspect the handoff."
        }
      ]

      record = ResultStoreContract.log_record(run_id: "jsonb-review-proposals", review_proposed_tasks: proposals)

      assert roundtrip(record).review_proposed_tasks == proposals
    end

    test "approved-then-found-red fact round-trips as an open reviewer-keyed map" do
      fact = %{
        "reviewer_adapter" => Atom.to_string(Codex),
        "reviewer_agent" => "codex",
        "reviewer_model" => "gpt-5.5",
        "review_facets" => %{"surface" => "otp"},
        "domains" => ["otp"],
        "cold_check" => %{"passed" => false, "command" => "mix precommit", "tail" => "red"}
      }

      record =
        ResultStoreContract.log_record(
          run_id: "jsonb-approved-then-found-red",
          reviewer_adapter: Codex,
          reviewer_model: "gpt-5.5",
          approved_then_found_red: fact
        )

      decoded = roundtrip(record)

      assert decoded.reviewer_model == "gpt-5.5"
      assert decoded.approved_then_found_red == fact
    end

    test "list-valued fields round-trip via the $list marker (composed_inputs, domains)" do
      composed = [%{phase: :initial, attempt: 0, argv: ["-p", "do it"]}]

      record =
        ResultStoreContract.log_record(
          run_id: "jsonb-lists",
          composed_inputs: composed,
          domains: [:otp, :oban]
        )

      decoded = roundtrip(record)

      assert decoded.composed_inputs == composed
      assert decoded.domains == [:otp, :oban]
    end

    test "agent/adapter/state/verdict atom columns round-trip" do
      record =
        ResultStoreContract.log_record(
          run_id: "jsonb-atoms",
          agent: :codex,
          adapter: Codex,
          state: :failed,
          verdict: :reject
        )

      decoded = roundtrip(record)

      assert decoded.agent == :codex
      assert decoded.adapter == Codex
      assert decoded.state == :failed
      assert decoded.verdict == :reject
    end
  end

  describe "never-raise contract (codec failures)" do
    test "an unencodable kind returns {:error, _}, never raises into the caller" do
      # A pid inside the kind tuple has no JSON representation — Jason raises,
      # record_run's rescue must convert it to {:error, _} (behaviour contract).
      record =
        ResultStoreContract.log_record(run_id: "kind-bad", agent_outcome_kind: {:error, self()})

      assert {:error, %Protocol.UndefinedError{}} = Postgres.record_run(record, repo: FakeRepo)
    end

    test "a DB failure returns {:error, _}, never raises" do
      record = ResultStoreContract.log_record(run_id: "db-down")

      assert {:error, %DBConnection.ConnectionError{}} =
               Postgres.record_run(record, repo: RaisingRepo)
    end

    test "a programmer error (undefined repo fn) propagates rather than being masked" do
      record = ResultStoreContract.log_record(run_id: "no-repo")

      assert_raise UndefinedFunctionError, fn ->
        Postgres.record_run(record, repo: RepoModuleThatDoesNotExist)
      end
    end
  end

  describe "aggregate row projections" do
    test "aggregate_by_agent projects DB rows through the shared KPI shape" do
      FakeRepo.put_rows([
        %{
          agent: "codex",
          run_count: 3,
          pass_count: 2,
          first_attempt_pass_count: 1,
          reviewer_flaked_count: 1,
          durations: [100, 200, 300],
          review_iterations_mean: 0.5,
          input_mean: 10,
          output_mean: 5,
          total_mean: 15,
          pass_count_for_cost: 2,
          cost_to_green_mean: 42,
          ratings: [%{"review_skills" => %{"otp" => %{"score" => 8}}, "review_ratings" => %{}}]
        }
      ])

      assert {:ok, %{codex: kpi}} = Postgres.aggregate_by_agent([], repo: FakeRepo)

      assert kpi.run_count == 3
      assert kpi.reviewer_flaked == 1
      assert kpi.success_rate == 1.0
      assert kpi.first_attempt_pass_rate == 0.5
      assert kpi.tokens == %TokenMeans{input: 10.0, output: 5.0, total: 15.0}
      assert kpi.review_iterations == 0.5
      assert kpi.ratings == %{"otp" => 8.0}
      assert kpi.cost_to_green == 42.0
    end

    test "aggregate_reviewer_reliability projects reviewer rows" do
      FakeRepo.put_rows([
        %{
          reviewer_adapter: Atom.to_string(Codex),
          reviewer_model: "gpt-5.5",
          reviewed_count: 4,
          rejection_count: 1,
          no_verdict_count: 1,
          false_approval_count: 1
        }
      ])

      assert {:ok, %{Codex => kpi}} = Postgres.aggregate_reviewer_reliability([], repo: FakeRepo)

      assert kpi.reviewed_count == 4
      assert kpi.rejection_count == 1
      assert kpi.rejection_rate == 0.25
      assert kpi.no_verdict_count == 1
      assert kpi.no_verdict_rate == 0.25
      assert kpi.false_approval_count == 1
      assert kpi.false_approval_rate == 0.25
      assert kpi.by_model["gpt-5.5"].false_approval_count == 1
    end

    test "aggregate_by_facet groups facet rows and projects per-agent KPIs" do
      FakeRepo.put_rows([
        %{
          facet_json: %{"surface" => "otp"},
          agent: "codex",
          run_count: 2,
          pass_count: 1,
          first_attempt_pass_count: 1,
          reviewer_flaked_count: 0,
          durations: [100, 200],
          review_iterations_mean: 0,
          input_mean: 10,
          output_mean: 5,
          total_mean: 15,
          pass_count_for_cost: 1,
          cost_to_green_mean: 15,
          ratings: [%{"review_skills" => %{"test_rigor" => %{"score" => 9}}, "review_ratings" => %{}}]
        },
        %{
          facet_json: %{"surface" => "otp"},
          agent: "claude",
          run_count: 1,
          pass_count: 0,
          first_attempt_pass_count: 0,
          reviewer_flaked_count: 0,
          durations: [300],
          review_iterations_mean: 1,
          input_mean: 20,
          output_mean: 10,
          total_mean: 30,
          pass_count_for_cost: 0,
          cost_to_green_mean: nil,
          ratings: []
        }
      ])

      assert {:ok, [%{facet: %{"surface" => "otp"}, agents: agents}]} =
               Postgres.aggregate_by_facet([], repo: FakeRepo)

      assert agents.codex.success_rate == 0.5
      assert agents.codex.ratings == %{"test_rigor" => 9.0}
      assert agents.claude.success_rate == 0.0
      assert agents.claude.cost_to_green == nil
    end
  end

  describe "batch and run mutators" do
    test "save_batch and load_batch round-trip a serialized batch result" do
      FakeRepo.reset()

      result = %BatchResult{
        batch_id: "batch-codec",
        total: 2,
        max_concurrency: 1,
        results: [],
        events: [%{event: :started}]
      }

      assert :ok = Postgres.save_batch(result, repo: FakeRepo)
      assert {:ok, ^result} = Postgres.load_batch("batch-codec", repo: FakeRepo)
    end

    test "load_batch returns not_found for a missing batch" do
      FakeRepo.reset()

      assert {:error, :not_found} = Postgres.load_batch("missing-batch", repo: FakeRepo)
    end

    test "delete_run and mark_landed return ok through repo success responses" do
      assert :ok = Postgres.delete_run("codec-run", repo: FakeRepo)
      assert :ok = Postgres.mark_landed("codec-run", "abc123", repo: FakeRepo)
    end
  end

  @spec roundtrip(LogRecord.t()) :: LogRecord.t()
  defp roundtrip(record) do
    assert :ok = Postgres.record_run(record, repo: FakeRepo)

    assert {:ok, [decoded]} =
             Postgres.list_run_records([run_id: record.run_id], repo: FakeRepo)

    decoded
  end
end
