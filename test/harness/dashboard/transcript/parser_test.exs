defmodule Harness.Dashboard.Transcript.ParserTest do
  # Fixture-driven tests for the per-agent transcript parser (Task 86).
  #
  # Each fixture under test/fixtures/transcripts/ holds a trimmed slice of
  # real raw output captured from a harness run (`agent_output` field of a
  # %Harness.Run.LogRecord{} on disk under ~/.harness/results/runs/). The
  # last line of every NDJSON fixture is deliberately malformed so the
  # `:unknown` preservation contract is exercised end-to-end.

  use ExUnit.Case, async: true

  alias Harness.Dashboard.Transcript.Parser

  @fixtures_dir [__DIR__, "..", "..", "..", "fixtures", "transcripts"] |> Path.join() |> Path.expand()

  defp read_fixture(name), do: File.read!(Path.join(@fixtures_dir, name))

  defp event_kinds(events), do: Enum.map(events, &elem(&1, 0))

  # Feeds the fixture all at once and finalizes the parser. Returns the
  # complete event list — the canonical "the entire transcript was already
  # delivered" path.
  defp parse_full(agent, body) do
    {events, parser} = Parser.append(agent, body, Parser.init_state(agent))
    {final_events, _parser} = Parser.finalize(agent, parser)
    events ++ final_events
  end

  # Feeds the fixture one byte at a time so the line buffer must reassemble
  # every event across chunk boundaries. The emitted event list must equal
  # `parse_full/2` — partial-line buffering must produce no observable
  # difference.
  defp parse_bytewise(agent, body) do
    {events, parser} =
      body
      |> :binary.bin_to_list()
      |> Enum.reduce({[], Parser.init_state(agent)}, fn byte, {acc, p} ->
        {evs, p2} = Parser.append(agent, <<byte>>, p)
        {acc ++ evs, p2}
      end)

    {final_events, _parser} = Parser.finalize(agent, parser)
    events ++ final_events
  end

  describe "dispatch table" do
    test "init_state/1 covers every agent in Harness.AgentRegistry.agents/0" do
      registered = Harness.AgentRegistry.agents() |> Map.keys() |> Enum.sort()

      for agent <- registered do
        # Must not raise — every adapter atom needs a parser today.
        assert _state = Parser.init_state(agent)
      end
    end

    test "init_state/1 raises ArgumentError for an unknown agent" do
      assert_raise ArgumentError, fn -> Parser.init_state(:not_a_real_agent) end
    end

    test "append/3 and finalize/2 round-trip an empty chunk for every agent" do
      for agent <- [:claude, :codex, :cursor, :pi, :grok, :antigravity] do
        state = Parser.init_state(agent)
        assert {[], state2} = Parser.append(agent, "", state)
        assert {[], _state3} = Parser.finalize(agent, state2)
      end
    end
  end

  describe "Claude fixture (claude -p --output-format stream-json)" do
    test "emits the unified event sequence for a real claude transcript" do
      events = parse_full(:claude, read_fixture("claude.ndjson"))

      assert event_kinds(events) == [
               :system,
               :assistant_text,
               :assistant_tool_use,
               :tool_result,
               :system,
               :unknown
             ]

      # System init carries its kind
      [{:system, sys_init} | _] = events
      assert sys_init.kind == :init
      assert sys_init.data["session_id"] == "abc-123"

      # Assistant text payload
      {:assistant_text, %{text: text}} = Enum.at(events, 1)
      assert text =~ "One failure exists"

      # Tool use carries id+name+input
      {:assistant_tool_use, tu} = Enum.at(events, 2)
      assert tu.id == "toolu_017v1m4mcVg7YvmjfWkv5n16"
      assert tu.name == "Read"
      assert tu.input == %{}

      # Tool result tags the use_id and content
      {:tool_result, tr} = Enum.at(events, 3)
      assert tr.tool_use_id == "toolu_01FgJs8dUL5pYCQYqwV33WAg"
      assert tr.content == "credo.ex"

      # System result terminal
      {:system, sys_result} = Enum.at(events, 4)
      assert sys_result.kind == :result

      # Corrupt trailing line preserved
      {:unknown, %{raw: raw}} = List.last(events)
      assert raw =~ "broken json"
    end

    test "byte-at-a-time feeding emits the same events as one-shot" do
      body = read_fixture("claude.ndjson")
      assert parse_bytewise(:claude, body) == parse_full(:claude, body)
    end
  end

  describe "Codex fixture (codex exec --json)" do
    test "emits the unified event sequence for a real codex transcript" do
      events = parse_full(:codex, read_fixture("codex.ndjson"))

      assert event_kinds(events) == [
               # Leading non-JSON codex_core ERROR line
               :unknown,
               :system,
               :system,
               :assistant_text,
               :assistant_tool_use,
               :tool_result,
               :system,
               :unknown
             ]

      # Non-JSON stderr line preserved
      {:unknown, %{raw: stderr_line}} = hd(events)
      assert stderr_line =~ "ERROR codex_core"

      # thread.started → :system kind=thread_started
      {:system, thread} = Enum.at(events, 1)
      assert thread.kind == :thread_started

      # turn.started → :system kind=turn_started
      {:system, turn} = Enum.at(events, 2)
      assert turn.kind == :turn_started

      # agent_message item → :assistant_text
      {:assistant_text, %{text: text}} = Enum.at(events, 3)
      assert text =~ "Credo"

      # command_execution item.started → :assistant_tool_use
      {:assistant_tool_use, tu} = Enum.at(events, 4)
      assert tu.id == "item_11"
      assert tu.name == "command_execution"
      assert %{command: cmd} = tu.input
      assert cmd =~ "git add"

      # command_execution item.completed → :tool_result
      {:tool_result, tr} = Enum.at(events, 5)
      assert tr.tool_use_id == "item_11"
      assert tr.content.exit_code == 0
      assert tr.content.status == "completed"

      # turn.completed → :system kind=turn_completed
      {:system, turn_done} = Enum.at(events, 6)
      assert turn_done.kind == :turn_completed

      # Trailing corrupt line preserved
      {:unknown, %{raw: raw}} = List.last(events)
      assert raw =~ "broken"
    end

    test "byte-at-a-time feeding emits the same events as one-shot" do
      body = read_fixture("codex.ndjson")
      assert parse_bytewise(:codex, body) == parse_full(:codex, body)
    end

    # Codex emits several complete agent_message items per turn; each carries a
    # trailing blank line so the renderer's consecutive-text fold separates them
    # into paragraphs instead of one undifferentiated wall of text.
    test "agent_message text carries a trailing separator for the fold" do
      transcript = """
      {"type":"item.completed","item":{"type":"agent_message","text":"First message."}}
      {"type":"item.completed","item":{"type":"agent_message","text":"Second message."}}
      """

      events = parse_full(:codex, transcript)

      assert [
               {:assistant_text, %{text: "First message.\n\n"}},
               {:assistant_text, %{text: "Second message.\n\n"}}
             ] = events
    end
  end

  describe "Cursor fixture (cursor-agent -p --output-format stream-json)" do
    test "emits the unified event sequence for a real cursor transcript" do
      events = parse_full(:cursor, read_fixture("cursor.ndjson"))

      assert event_kinds(events) == [
               :system,
               :assistant_text,
               :system,
               :unknown
             ]

      [{:system, init}, {:assistant_text, %{text: text}}, {:system, result}, {:unknown, %{raw: corrupt}}] = events
      assert init.kind == :init
      assert init.data["model"] == "Composer 2.5 Fast"
      assert text =~ "Updating test files"
      assert result.kind == :result
      assert corrupt =~ "not json"
    end

    test "byte-at-a-time feeding emits the same events as one-shot" do
      body = read_fixture("cursor.ndjson")
      assert parse_bytewise(:cursor, body) == parse_full(:cursor, body)
    end

    # Cursor's real tool_call wire shape (`{type: tool_call, tool_call:
    # {<kind>ToolCall: {...}}}`) diverges from Claude's assistant/tool_use
    # blocks. The fixture above predates real tool use, so these inline
    # transcripts pin the divergent shape that previously fell through to
    # `:other` (bare "OTHER" eyebrow rows, no tool card).
    test "tool_call started/completed map to assistant_tool_use + tool_result" do
      transcript = """
      {"type":"tool_call","subtype":"started","call_id":"tool_abc","tool_call":{"readToolCall":{"args":{"path":"/repo/lib/foo.ex"}}}}
      {"type":"tool_call","subtype":"completed","call_id":"tool_abc","tool_call":{"readToolCall":{"args":{"path":"/repo/lib/foo.ex"},"result":{"success":{"content":"defmodule Foo"}}}}}
      """

      events = parse_full(:cursor, transcript)

      assert [
               {:assistant_tool_use, %{id: "tool_abc", name: "read", input: %{"path" => "/repo/lib/foo.ex"}}},
               {:tool_result, %{tool_use_id: "tool_abc", content: %{"success" => %{"content" => "defmodule Foo"}}}}
             ] = events
    end

    test "tool name derives from the inner key minus its ToolCall suffix" do
      for {inner, name} <- [
            {"readToolCall", "read"},
            {"grepToolCall", "grep"},
            {"editToolCall", "edit"},
            {"shellToolCall", "shell"},
            {"globToolCall", "glob"}
          ] do
        line = ~s({"type":"tool_call","subtype":"started","call_id":"c","tool_call":{"#{inner}":{"args":{}}}}\n)
        assert [{:assistant_tool_use, %{name: ^name}}] = parse_full(:cursor, line)
      end
    end

    test "thinking deltas surface as :thought system events (the reasoning lane)" do
      transcript = """
      {"type":"thinking","subtype":"delta","text":"The failing test "}
      {"type":"thinking","subtype":"delta","text":"uses the old name."}
      """

      events = parse_full(:cursor, transcript)

      assert [
               {:system, %{kind: :thought, data: %{text: "The failing test "}}},
               {:system, %{kind: :thought, data: %{text: "uses the old name."}}}
             ] = events
    end
  end

  describe "Pi fixture (pi -p --mode json)" do
    test "emits the unified event sequence for a real pi transcript" do
      events = parse_full(:pi, read_fixture("pi.ndjson"))

      assert event_kinds(events) == [
               :system,
               :system,
               :system,
               :assistant_text,
               :system,
               :system,
               :unknown
             ]

      # Session / agent_start / turn_start banner trio
      [{:system, session}, {:system, agent}, {:system, turn} | _] = events
      assert session.kind == :session
      assert agent.kind == :agent_start
      assert turn.kind == :turn_start

      # text_delta → assistant_text with payload extracted from "delta"
      {:assistant_text, %{text: delta}} = Enum.at(events, 3)
      assert delta == "Our"

      # text_start → :system kind=text_start (not an assistant_text — it
      # duplicates the first text_delta payload)
      {:system, text_start} = Enum.at(events, 4)
      assert text_start.kind == :text_start

      # message_end → :system kind=message_end
      {:system, msg_end} = Enum.at(events, 5)
      assert msg_end.kind == :message_end

      # Trailing corrupt line preserved
      {:unknown, %{raw: raw}} = List.last(events)
      assert raw =~ "missing closing"
    end

    test "byte-at-a-time feeding emits the same events as one-shot" do
      body = read_fixture("pi.ndjson")
      assert parse_bytewise(:pi, body) == parse_full(:pi, body)
    end
  end

  describe "Grok fixture (grok -p --output-format streaming-json)" do
    test "emits the unified event sequence for a real grok transcript" do
      events = parse_full(:grok, read_fixture("grok.ndjson"))

      assert event_kinds(events) == [
               :unknown,
               :system,
               :system,
               :assistant_text,
               :assistant_text,
               :system,
               :unknown
             ]

      # Leading ANSI-coloured stderr noise preserved verbatim
      {:unknown, %{raw: ansi_line}} = hd(events)
      assert ansi_line =~ "Transport channel closed"

      # `thought` events → :system kind=:thought
      {:system, %{kind: :thought}} = Enum.at(events, 1)
      {:system, %{kind: :thought}} = Enum.at(events, 2)

      # `text` events → :assistant_text
      {:assistant_text, %{text: _}} = Enum.at(events, 3)
      {:assistant_text, %{text: _}} = Enum.at(events, 4)

      # `end` → :system kind=:end
      {:system, end_ev} = Enum.at(events, 5)
      assert end_ev.kind == :end
      assert end_ev.data["stopReason"] == "EndTurn"

      # Trailing corrupt line preserved
      {:unknown, %{raw: raw}} = List.last(events)
      assert raw =~ "broken"
    end

    test "byte-at-a-time feeding emits the same events as one-shot" do
      body = read_fixture("grok.ndjson")
      assert parse_bytewise(:grok, body) == parse_full(:grok, body)
    end
  end

  describe "Antigravity / passthrough" do
    test "emits exactly one :plain_text event per chunk, no JSON parsing" do
      body = read_fixture("antigravity.txt")

      events = parse_full(:antigravity, body)
      assert events == [{:plain_text, %{text: body}}]
    end

    test "multiple chunks emit one event per chunk (no line splitting)" do
      state = Parser.init_state(:antigravity)
      {ev1, state} = Parser.append(:antigravity, "first chunk\nstill first\n", state)
      {ev2, state} = Parser.append(:antigravity, "second chunk", state)
      {flush, _state} = Parser.finalize(:antigravity, state)

      assert ev1 == [{:plain_text, %{text: "first chunk\nstill first\n"}}]
      assert ev2 == [{:plain_text, %{text: "second chunk"}}]
      assert flush == []
    end

    test "empty chunks emit no events" do
      state = Parser.init_state(:antigravity)
      assert {[], state} = Parser.append(:antigravity, "", state)
      assert {[], _state} = Parser.finalize(:antigravity, state)
    end
  end

  describe "partial-line buffering edge cases" do
    test "feeding two halves of a single JSON line emits one event on the second" do
      first = ~s({"type":"text","data":"hel)
      second = ~s(lo"}\n)

      state = Parser.init_state(:grok)
      {ev1, state} = Parser.append(:grok, first, state)
      assert ev1 == []
      {ev2, _state} = Parser.append(:grok, second, state)
      assert ev2 == [{:assistant_text, %{text: "hello"}}]
    end

    test "a complete JSON object without trailing newline is parsed at finalize/2" do
      state = Parser.init_state(:grok)
      {[], state} = Parser.append(:grok, ~s({"type":"text","data":"only"}), state)
      {flushed, _state} = Parser.finalize(:grok, state)
      assert flushed == [{:assistant_text, %{text: "only"}}]
    end

    test "a malformed trailing fragment becomes :unknown at finalize/2" do
      state = Parser.init_state(:claude)
      {[], state} = Parser.append(:claude, ~s({not-json-at-all), state)
      {flushed, _state} = Parser.finalize(:claude, state)
      assert [{:unknown, %{raw: "{not-json-at-all"}}] = flushed
    end
  end
end
