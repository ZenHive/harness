defmodule Harness.Insights.ResponseSchema do
  @moduledoc "Provider output structure for findings and bounded read requests; no semantic grading."

  import Harness.ResponseSchema, only: [object: 1, array: 1]

  @doc "Returns the Codex CLI response schema."
  @spec schema() :: map()
  def schema do
    text = %{"type" => "string"}
    nullable_text = %{"type" => ["string", "null"]}
    fields = Map.new(~w(title explanation facts hypothesis improvement assessment contradictions recurrence), &{&1, text})
    citation = object(%{"source_id" => text, "excerpt" => text})
    finding = object(Map.merge(fields, %{"id" => nullable_text, "citations" => array(citation)}))

    read =
      object(%{
        "kind" => %{"type" => "string", "enum" => ["findings", "source"]},
        "source_id" => nullable_text,
        "offset" => %{"type" => "integer"}
      })

    object(%{"findings" => array(finding), "read" => %{"anyOf" => [read, %{"type" => "null"}]}})
  end
end
