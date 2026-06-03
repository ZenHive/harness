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

    @spec reset() :: :ok
    def reset do
      Process.put({__MODULE__, :rows}, [])
      :ok
    end

    @spec rows() :: [struct()]
    defp rows, do: Process.get({__MODULE__, :rows}, [])
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

    test "an unavailable repo module returns {:error, _}, never raises" do
      record = ResultStoreContract.log_record(run_id: "no-repo")

      assert {:error, %UndefinedFunctionError{}} =
               Postgres.record_run(record, repo: RepoModuleThatDoesNotExist)
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
