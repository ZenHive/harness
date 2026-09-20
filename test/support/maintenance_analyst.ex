defmodule Harness.Test.MaintenanceAnalyst do
  @moduledoc false

  @spec assess(String.t(), map(), map()) :: {:ok, map()} | {:error, atom()}
  def assess(_path, context, _settings) do
    if hook = Application.get_env(:harness, :maintenance_test_hook), do: hook.(context)

    case Application.get_env(:harness, :maintenance_test_mode) do
      :fail ->
        {:error, :agent_failed}

      :unsafe ->
        {:ok, response([], false)}

      :empty ->
        {:ok, response([], true)}

      :blocked ->
        {:ok,
         response(
           Enum.map(
             findings(context),
             &Map.merge(&1, %{
               "blocked" => true,
               "rationale" => "Consumer credentials unavailable; migration verification is blocked."
             })
           ),
           true
         )}

      _ ->
        {:ok, response(findings(context), true)}
    end
  end

  @spec findings(map()) :: [map()]
  defp findings(%{"mode" => "discovery"} = context) do
    if context["previous_findings"] == [], do: Enum.map(1..5, &finding/1), else: context["previous_findings"]
  end

  defp findings(context) do
    context["previous_findings"]
    |> Enum.with_index()
    |> Enum.map(fn {finding, index} -> Map.put(finding, "selected", index < context["available_slots"]) end)
  end

  @spec response([map()], boolean()) :: map()
  defp response(findings, safe),
    do: %{
      "findings" => findings,
      "partial_evidence" => true,
      "publication_safe" => safe,
      "rationale" => "Mechanical publication fixture; no external semantics are graded."
    }

  @spec finding(integer()) :: map()
  defp finding(n) do
    %{
      "id" => nil,
      "title" => "Simplify fixture #{n}",
      "category" => "refactoring",
      "evidence" => "README.md:1",
      "rationale" => "Controlled recovery fixture",
      "improvement" => "Remove duplicate fixture text",
      "outcome" => "Unverified",
      "blocked" => false,
      "selected" => true,
      "task" => %{
        "title" => "Simplify fixture #{n}",
        "body" =>
          "Remove duplicate fixture text; retain documented behavior. Score rationale: bounded single-file simplification.",
        "bundle" => "maintenance",
        "assignee" => "codex",
        "model" => "gpt-6-astra",
        "phase" => 1,
        "d" => 1,
        "b" => 2,
        "u" => 1,
        "files_to_modify" => ["README.md"],
        "touches" => ["README.md"],
        "acceptance_criteria" => ["Independently compare documented behavior before and after."],
        "out_of_scope" => []
      }
    }
  end
end
