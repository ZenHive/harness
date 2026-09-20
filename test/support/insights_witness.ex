defmodule Harness.Test.InsightsWitness do
  @moduledoc false
  @behaviour Harness.Insights.Witness

  @impl Harness.Insights.Witness
  @spec observe(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def observe(evidence, model) do
    send(Application.fetch_env!(:harness, :insights_test_owner), {:observed, evidence, model})

    case Application.get_env(:harness, :insights_test_response, :finding) do
      :finding ->
        source = Enum.find(evidence["sources"], &(&1["text"] != ""))
        existing = List.first(evidence["previous_findings"])
        {:ok, %{"findings" => [finding(source, existing && existing["id"])]}}

      response ->
        response
    end
  end

  @doc false
  @spec finding(map(), String.t() | nil) :: map()
  def finding(source, id \\ nil) do
    %{
      "id" => id,
      "title" => "Repeated reviewer repairs",
      "explanation" => "Reviewers repaired repeated omissions.",
      "facts" => "Cited run evidence",
      "hypothesis" => "The implementation checks may be incomplete.",
      "improvement" => "Check the cited requirements before review.",
      "assessment" => "Needs later evidence",
      "contradictions" => "No contradictory evidence in this page",
      "recurrence" => "Review again on later runs",
      "citations" => [%{"source_id" => source["source_id"], "excerpt" => source["text"]}]
    }
  end
end
