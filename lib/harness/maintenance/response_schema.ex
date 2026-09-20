defmodule Harness.Maintenance.ResponseSchema do
  @moduledoc "Public assessment transport structure; relevance and disclosure remain AI judgments."

  @doc "Returns the disclosure review's structured response contract."
  @spec schema() :: map()
  def schema do
    text = %{"type" => "string"}
    boolean = %{"type" => "boolean"}
    task = Map.new(~w(title body bundle assignee model), &{&1, text})
    task = Enum.reduce(~w(files_to_modify touches acceptance_criteria out_of_scope), task, &Map.put(&2, &1, array(text)))
    task = Enum.reduce(~w(phase d b u), task, &Map.put(&2, &1, %{"type" => "integer"}))
    finding = Map.new(~w(title category evidence rationale improvement outcome), &{&1, text})

    finding =
      Map.merge(finding, %{
        "id" => %{"type" => ["string", "null"]},
        "blocked" => boolean,
        "selected" => boolean,
        "task" => %{"anyOf" => [object(task), %{"type" => "null"}]}
      })

    object(%{
      "findings" => array(object(finding)),
      "partial_evidence" => boolean,
      "publication_safe" => boolean,
      "rationale" => text
    })
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
