defmodule Harness.AgentModelTest do
  use ExUnit.Case, async: true

  alias Harness.AgentModel

  describe "parse/2 — agents that report a model" do
    test "claude reads the model id off a top-level model key" do
      transcript = """
      {"type":"system","subtype":"init","model":"claude-opus-4-8"}
      {"type":"assistant","message":{"content":"hi"}}
      """

      assert AgentModel.parse(:claude, transcript) == "claude-opus-4-8"
    end

    test "cursor reads the model id off its init event" do
      transcript = ~s({"type":"system","subtype":"init","model":"Composer 2.5 Fast"}\n)
      assert AgentModel.parse(:cursor, transcript) == "Composer 2.5 Fast"
    end

    test "a nested message.model is accepted for wire drift" do
      transcript = ~s({"type":"assistant","message":{"model":"claude-sonnet-4-6","content":"x"}}\n)
      assert AgentModel.parse(:claude, transcript) == "claude-sonnet-4-6"
    end

    test "returns the first model found and ignores later restatements" do
      transcript = """
      {"type":"system","subtype":"init","model":"claude-opus-4-8"}
      {"type":"result","model":"claude-opus-4-8"}
      """

      assert AgentModel.parse(:claude, transcript) == "claude-opus-4-8"
    end
  end

  describe "parse/2 — agents that do not report a model" do
    test "codex / grok / antigravity / unknown / nil yield nil" do
      # A codex command string mentions a path, not a model key — must not match.
      codex = ~s({"type":"item.completed","item":{"type":"command_execution","command":"cat lib/model.ex"}}\n)
      assert AgentModel.parse(:codex, codex) == nil
      assert AgentModel.parse(:grok, ~s({"type":"text","data":"the model is"}\n)) == nil
      assert AgentModel.parse(:antigravity, "plain text") == nil
      assert AgentModel.parse(:made_up, ~s({"model":"x"}\n)) == nil
      assert AgentModel.parse(nil, "whatever") == nil
    end
  end

  describe "parse/2 — tolerant fallbacks" do
    test "non-binary output never crashes" do
      assert AgentModel.parse(:claude, nil) == nil
      assert AgentModel.parse(:claude, 42) == nil
    end

    test "malformed lines and empty/absent model are skipped" do
      transcript = """
      {"type": "broken json no close
      {"type":"system","subtype":"init","model":""}
      {"type":"assistant","message":{"content":"hi"}}
      """

      assert AgentModel.parse(:claude, transcript) == nil
    end
  end
end
