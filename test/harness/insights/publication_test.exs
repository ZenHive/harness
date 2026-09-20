defmodule Harness.Insights.PublicationTest do
  use ExUnit.Case, async: true

  alias Harness.Insights.Evidence
  alias Harness.Insights.Publication
  alias Harness.Test.InsightsWitness

  test "citations retain exact excerpts, source reference and provisional status" do
    source = Evidence.source("run-a", "project", "transcript", "reviewer fixed a missing check", true)
    response = %{"findings" => [InsightsWitness.finding(source)]}

    assert {:ok, [{_, "finding", finding}, {_, _, revision}]} =
             Publication.prepare(response, [source], [], "pass", %{"agent" => "claude"})

    assert finding == revision
    assert finding["provisional"]
    assert finding["runs"] == ["run-a"]
    assert hd(finding["citations"])["excerpt"] == source["text"]
    refute Map.has_key?(finding, "commands")
  end

  test "rejects malformed findings, unknown ids, duplicate revisions and invented citations" do
    source = Evidence.source("run-a", "project", "record", "facts", false)
    finding = InsightsWitness.finding(source)

    for findings <- [
          [nil],
          [1],
          [%{}],
          [Map.put(finding, "id", "unknown")],
          [put_in(finding, ["citations"], [%{"source_id" => "unknown", "excerpt" => "facts"}])],
          [put_in(finding, ["citations"], [%{"source_id" => source["source_id"], "excerpt" => "invented"}])],
          [Map.put(finding, "citations", [])]
        ] do
      assert {:error, _} = Publication.prepare(%{"findings" => findings}, [source], [], "pass", %{})
    end

    existing = Map.put(finding, "id", "known")
    assert {:error, _} = Publication.prepare(%{"findings" => [existing, existing]}, [source], [existing], "pass", %{})
    assert {:error, _} = Publication.prepare(%{}, [source], [], "pass", %{})
    assert {:ok, []} = Publication.prepare(%{"findings" => []}, [source], [], "pass", %{})
  end

  test "missing and truncated sources are explicit and bounded" do
    assert Evidence.source("a", "p", "transcript", nil, true)["availability"] == "unavailable"
    assert Evidence.source("a", "p", "transcript", "", true)["availability"] == "unavailable"
    source = Evidence.source("a", "p", "transcript", String.duplicate("x", 8001), true)
    assert source["availability"] == "truncated"
    assert byte_size(source["text"]) == 8000
  end
end
