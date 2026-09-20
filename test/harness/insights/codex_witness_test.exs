defmodule Harness.Insights.CodexWitnessTest do
  use ExUnit.Case, async: false

  alias Harness.Insights.CodexWitness

  test "only a completed turn with a valid final JSON message can publish" do
    message = fn text -> %{"type" => "item.completed", "item" => %{"type" => "agent_message", "text" => text}} end
    completed = %{"type" => "turn.completed"}
    encode = fn events -> Enum.map_join(events, "\n", &Jason.encode!/1) end
    assert {:ok, %{"findings" => []}} = CodexWitness.decode(encode.([message.(~s({"findings":[]})), completed]))

    assert {:ok, %{"findings" => []}} =
             CodexWitness.decode(encode.([message.("```json\n{\"findings\":[]}\n```"), completed]))

    assert {:error, {:incomplete_codex_turn, _}} = CodexWitness.decode(encode.([message.(~s({"findings":[]}))]))
    assert {:error, {:incomplete_codex_turn, _}} = CodexWitness.decode(encode.([completed, %{"type" => "turn.failed"}]))
    assert {:error, :missing_agent_message} = CodexWitness.decode(encode.([completed]))

    assert {:error, {:malformed_agent_output, "not json"}} =
             CodexWitness.decode(encode.([message.("not json"), completed]))

    assert {:error, {:malformed_agent_output, "[]"}} = CodexWitness.decode(encode.([message.("[]"), completed]))
  end

  test "a missing Codex executable never invokes Claude" do
    path = System.get_env("PATH")
    System.put_env("PATH", "")
    on_exit(fn -> System.put_env("PATH", path) end)
    assert {:error, :codex_not_installed} = CodexWitness.observe(%{}, "gpt-6-astra")
  end
end
