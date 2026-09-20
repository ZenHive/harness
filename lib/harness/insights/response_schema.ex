defmodule Harness.Insights.ResponseSchema do
  @moduledoc "Provider output structure for findings and bounded read requests; no semantic grading."

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

  @spec object(map()) :: map()
  defp object(properties),
    do: %{
      "type" => "object",
      "properties" => properties,
      "required" => Map.keys(properties),
      "additionalProperties" => false
    }

  @spec array(map()) :: map()
  defp array(items), do: %{"type" => "array", "items" => items}
end
