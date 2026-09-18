defmodule Harness.Dispatch.DecisionTest do
  use ExUnit.Case, async: true

  alias Harness.Dispatch.Decision
  alias Harness.ProjectFixture

  test "prior history requires an explicit action, reason and model" do
    project = ProjectFixture.from_repo("/tmp/decision")
    task = task([attempt()])
    entry = %{"adapter" => "codex"}
    assert {:error, :explicit_action_required} = Decision.capture(project, task, entry)
    entry = Map.put(entry, "action", "fresh")
    assert {:error, :reason_required} = Decision.capture(project, task, entry)
    entry = Map.put(entry, "reason", "Replace incompatible implementation")
    assert {:error, :model_required} = Decision.capture(project, task, entry)
    entry = Map.put(entry, "model", "gpt-6-astra")
    assert {:ok, decision} = Decision.capture(project, task, entry)
    assert decision["action"] == "fresh"
    assert decision["history_run_ids"] == ["prior"]
    assert decision["task_fingerprint"] == "content"
  end

  test "recovery captures the exact selected tip and refuses unavailable sources" do
    project = ProjectFixture.from_repo("/tmp/decision")
    entry = %{action: "resume", adapter: "codex", model: "gpt-6-astra", reason: "Keep work", source_run_id: "prior"}

    assert {:ok, %{"selected_sha" => "abc", "source_run_id" => "prior"}} =
             Decision.capture(project, task([attempt()]), entry)

    assert {:error, :invalid_source_run} = Decision.capture(project, task([]), entry)
    landed = put_in(attempt(), ["git", "on_origin"], true)
    assert {:error, :source_unavailable_or_landed} = Decision.capture(project, task([landed]), entry)
    assert {:error, :fresh_with_source} = Decision.capture(project, task([attempt()]), %{entry | action: "fresh"})
    assert {:ok, %{"action" => "rereview"}} = Decision.capture(project, task([attempt()]), %{entry | action: "rereview"})
  end

  test "old first-attempt plan remains compatible" do
    project = ProjectFixture.from_repo("/tmp/decision")
    assert {:ok, %{"action" => "fresh"}} = Decision.capture(project, task([]), %{adapter: "codex"})
  end

  defp task(attempts), do: %{"id" => "1", "task_fingerprint" => "content", "attempts" => attempts}

  defp attempt,
    do: %{
      "run_id" => "prior",
      "task_id" => "1",
      "task_ids" => ["1"],
      "landed_sha" => nil,
      "git" => %{"selected_sha" => "abc", "on_origin" => false}
    }
end
