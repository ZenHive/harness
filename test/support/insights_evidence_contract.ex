defmodule Harness.Test.InsightsEvidenceContract do
  @moduledoc false
  defmacro __using__(opts) do
    quote do
      alias Harness.Insights
      alias Harness.Insights.Evidence
      alias Harness.Insights.Store
      alias Harness.ResultStore

      @tag unquote(opts)
      test "structured reviewer concerns are available and concern-only updates reach the witness" do
        first = evidence_record(review_concerns: ["REVIEW_CONCERN_ALPHA"])
        :ok = ResultStore.record_run(first)
        :ok = Insights.observe("concern-first")
        assert_received {:observed, context, _}
        assert Jason.encode!(context["sources"]) =~ "REVIEW_CONCERN_ALPHA"
        :ok = ResultStore.record_run(%{first | review_concerns: ["REVIEW_CONCERN_BETA"]})
        :ok = Insights.observe("concern-second")
        assert_received {:observed, changed, _}
        assert Jason.encode!(changed["sources"]) =~ "REVIEW_CONCERN_BETA"
      end

      @tag unquote(opts)
      test "an old relevant finding gets the changed evidence before it is consumed" do
        :ok =
          Store.put_many([
            {"finding/old", "finding",
             %{
               "id" => "old",
               "title" => "Original recurring problem",
               "projects" => ["review"],
               "runs" => ["review-run"],
               "citations" => []
             }}
          ])

        :ok =
          Store.put_many(
            for n <- 1..10,
                do:
                  {"finding/new-#{n}", "finding",
                   %{"id" => "new-#{n}", "title" => "Unrelated", "projects" => ["other"], "runs" => [], "citations" => []}}
          )

        :ok = ResultStore.record_run(evidence_record(review_report: "The original recurring problem returned"))
        :ok = Insights.observe("memory-first")
        assert_received {:observed, context, _}
        :ok = Insights.observe("memory-next")
        refute_received {:observed, _, _}
        assert Enum.any?(context["previous_findings"], &(&1["id"] == "old"))
      end

      @tag unquote(opts)
      test "source marked available does not silently lose review report content" do
        :ok = ResultStore.record_run(evidence_record(review_report: String.duplicate("x", 5000) <> "TAIL_REVIEW_FINDING"))
        {:ok, batch} = Evidence.batch(%{})
        source = Enum.find(batch.sources, &(&1["field"] == "record"))
        assert source["availability"] == "available"
        assert source["text"] =~ "TAIL_REVIEW_FINDING"
      end

      @tag unquote(opts)
      test "all retained facts and changes beyond source excerpts remain observable" do
        report = String.duplicate("界", 9000) <> "BEYOND_EXCERPT_ALPHA"

        first =
          evidence_record(
            review_report: report,
            reason: {:failed, "REASON_ALPHA"},
            review_checks: %{"check" => "CHECK_ALPHA"}
          )

        :ok = ResultStore.record_run(first)
        {:ok, batch} = Evidence.batch(%{})
        source = Enum.find(batch.sources, &(&1["field"] == "record"))
        assert source["availability"] == "truncated"
        assert byte_size(source["text"]) <= 8000
        text = read_all(batch, source)
        assert text =~ "BEYOND_EXCERPT_ALPHA"
        assert text =~ "REASON_ALPHA"
        assert text =~ "CHECK_ALPHA"
        assert :ok = Insights.observe("long-first")
        :ok = ResultStore.record_run(%{first | review_report: String.replace(report, "ALPHA", "BETA")})
        assert :ok = Insights.observe("long-second")
        assert Insights.status()["last_pass"]["changed_runs"] == 1
        :ok = ResultStore.record_run(%{first | reason: {:failed, "REASON_BETA"}})
        assert :ok = Insights.observe("reason-change")
        assert Insights.status()["last_pass"]["changed_runs"] == 1
        :ok = ResultStore.record_run(%{first | review_checks: %{"check" => "CHECK_BETA"}})
        assert :ok = Insights.observe("check-change")
        assert Insights.status()["last_pass"]["changed_runs"] == 1
        assert {:error, :unknown_source_or_offset} = Evidence.read(batch, "missing", 0)
        assert {:error, :invalid_source_offset} = Evidence.read(batch, source["source_id"], -1)
      end

      defp read_all(batch, source) do
        case source["next_offset"] do
          nil ->
            source["text"]

          offset ->
            {:ok, page} = Evidence.read(batch, source["root_source_id"] || source["source_id"], offset)
            assert String.valid?(page["text"])
            assert byte_size(page["text"]) <= 8000
            source["text"] <> read_all(batch, page)
        end
      end
    end
  end
end
