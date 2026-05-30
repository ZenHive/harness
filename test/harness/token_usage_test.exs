defmodule Harness.TokenUsageTest do
  use ExUnit.Case, async: true

  alias Harness.TokenUsage

  @fixtures Path.expand("../fixtures/transcripts", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  describe "empty/0 and measured?/1" do
    test "empty is all-nil and reports unmeasured" do
      assert %TokenUsage{input: nil, output: nil, cache_read: nil, cache_creation: nil, total: nil} = TokenUsage.empty()
      refute TokenUsage.measured?(TokenUsage.empty())
    end

    test "any populated field is measured" do
      assert TokenUsage.measured?(%TokenUsage{output: 0})
      assert TokenUsage.measured?(%TokenUsage{input: 5})
    end
  end

  describe "add/2" do
    test "sums component-wise treating nil as absent" do
      a = %TokenUsage{input: 10, output: 2, cache_read: nil, cache_creation: 5}
      b = %TokenUsage{input: 3, output: nil, cache_read: 7, cache_creation: nil}

      assert %TokenUsage{input: 13, output: 2, cache_read: 7, cache_creation: 5, total: 27} = TokenUsage.add(a, b)
    end

    test "adding empty is a no-op that preserves measured fields" do
      usage = %TokenUsage{input: 4, output: 8, total: 12}
      assert TokenUsage.add(usage, TokenUsage.empty()) == %{usage | total: 12}
      assert TokenUsage.add(TokenUsage.empty(), TokenUsage.empty()) == TokenUsage.empty()
    end
  end

  describe "parse/2 — Claude (Anthropic stream-json)" do
    test "prefers the terminal result event's cumulative usage" do
      transcript = """
      {"type":"assistant","message":{"usage":{"input_tokens":6,"cache_read_input_tokens":100,"output_tokens":1}}}
      {"type":"assistant","message":{"usage":{"input_tokens":1,"cache_read_input_tokens":200,"output_tokens":43}}}
      {"type":"result","subtype":"success","usage":{"input_tokens":7,"cache_creation_input_tokens":50,"cache_read_input_tokens":300,"output_tokens":44}}
      """

      assert %TokenUsage{input: 7, output: 44, cache_read: 300, cache_creation: 50, total: 401} =
               TokenUsage.parse(:claude, transcript)
    end

    test "falls back to summing assistant message usage when no result usage" do
      # The committed claude fixture has assistant usage but a usage-less result event.
      assert %TokenUsage{input: 7, output: 44, cache_read: 298_558, cache_creation: 1072} =
               usage = TokenUsage.parse(:claude, fixture("claude.ndjson"))

      assert usage.total == 7 + 44 + 298_558 + 1072
    end

    test "broken trailing JSON line is ignored, not fatal" do
      transcript = """
      {"type":"assistant","message":{"usage":{"input_tokens":5,"output_tokens":9}}}
      {"type": "broken json no closing brace
      """

      assert %TokenUsage{input: 5, output: 9, total: 14} = TokenUsage.parse(:claude, transcript)
    end
  end

  describe "parse/2 — Cursor (mirrors Anthropic shape)" do
    test "sums assistant usage" do
      transcript = """
      {"type":"system","subtype":"init"}
      {"type":"assistant","message":{"usage":{"input_tokens":12,"output_tokens":3}}}
      {"type":"result","subtype":"success","is_error":false}
      """

      assert %TokenUsage{input: 12, output: 3, total: 15} = TokenUsage.parse(:cursor, transcript)
    end

    test "usage-less committed fixture yields empty" do
      refute TokenUsage.measured?(TokenUsage.parse(:cursor, fixture("cursor.ndjson")))
    end
  end

  describe "parse/2 — Codex (turn.completed usage)" do
    test "sums usage across turn.completed events" do
      transcript = """
      {"type":"turn.started"}
      {"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":20}}
      {"type":"turn.completed","usage":{"input_tokens":40,"output_tokens":5}}
      """

      assert %TokenUsage{input: 140, output: 25, cache_read: 80, total: 245} = TokenUsage.parse(:codex, transcript)
    end

    test "usage-less committed fixture yields empty" do
      refute TokenUsage.measured?(TokenUsage.parse(:codex, fixture("codex.ndjson")))
    end
  end

  describe "parse/2 — Pi (dedup by responseId)" do
    test "collapses restated per-message usage then sums across messages" do
      transcript = """
      {"type":"message_update","message":{"usage":{"input":10,"output":1,"cacheRead":5},"responseId":"r1"}}
      {"type":"message_update","message":{"usage":{"input":10,"output":4,"cacheRead":5},"responseId":"r1"}}
      {"type":"message_update","message":{"usage":{"input":2,"output":6,"cacheWrite":3},"responseId":"r2"}}
      """

      # r1 collapses to its last snapshot (output 4), r2 contributes once.
      assert %TokenUsage{input: 12, output: 10, cache_read: 5, cache_creation: 3, total: 30} =
               TokenUsage.parse(:pi, transcript)
    end

    test "all-zero committed fixture parses without inflation" do
      assert %TokenUsage{input: 0, output: 0, cache_read: 0, cache_creation: 0, total: 0} =
               TokenUsage.parse(:pi, fixture("pi.ndjson"))
    end
  end

  describe "parse/2 — Grok (terminal end usage, best-effort)" do
    test "reads usage off the end event when present" do
      transcript = """
      {"type":"text","data":"hi"}
      {"type":"end","stopReason":"EndTurn","usage":{"input_tokens":30,"output_tokens":12}}
      """

      assert %TokenUsage{input: 30, output: 12, total: 42} = TokenUsage.parse(:grok, transcript)
    end

    test "usage-less committed fixture yields empty" do
      refute TokenUsage.measured?(TokenUsage.parse(:grok, fixture("grok.ndjson")))
    end
  end

  describe "repair-loop accumulation" do
    # Mirrors how Harness.Run sums each settled attempt: add(total, parse(kind, output)).
    test "summing per-attempt parses attributes a multi-attempt run's total burn" do
      attempt_1 = ~s({"type":"result","usage":{"input_tokens":100,"output_tokens":40}}\n)
      attempt_2 = ~s({"type":"result","usage":{"input_tokens":30,"output_tokens":120,"cache_read_input_tokens":900}}\n)

      total =
        TokenUsage.empty()
        |> TokenUsage.add(TokenUsage.parse(:claude, attempt_1))
        |> TokenUsage.add(TokenUsage.parse(:claude, attempt_2))

      assert %TokenUsage{input: 130, output: 160, cache_read: 900, total: 1190} = total
    end

    test "an unmeasured attempt does not erase an earlier attempt's burn" do
      measured = TokenUsage.parse(:claude, ~s({"type":"result","usage":{"input_tokens":7,"output_tokens":3}}\n))
      unmeasured = TokenUsage.parse(:antigravity, "plain text, no usage")

      assert %TokenUsage{input: 7, output: 3, total: 10} = TokenUsage.add(measured, unmeasured)
    end
  end

  describe "parse/2 — tolerant fallbacks" do
    test "antigravity plain text and unknown/nil kinds yield empty" do
      assert TokenUsage.empty() == TokenUsage.parse(:antigravity, fixture("antigravity.txt"))
      assert TokenUsage.empty() == TokenUsage.parse(nil, "whatever")
      assert TokenUsage.empty() == TokenUsage.parse(:made_up, "{}")
    end

    test "non-binary output never crashes" do
      assert TokenUsage.empty() == TokenUsage.parse(:claude, nil)
      assert TokenUsage.empty() == TokenUsage.parse(:claude, 42)
    end

    test "negative or non-integer counts are dropped" do
      transcript = ~s({"type":"result","usage":{"input_tokens":-5,"output_tokens":"x","cache_read_input_tokens":9}}\n)
      assert %TokenUsage{input: nil, output: nil, cache_read: 9, total: 9} = TokenUsage.parse(:claude, transcript)
    end
  end
end
