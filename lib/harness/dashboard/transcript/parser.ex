defmodule Harness.Dashboard.Transcript.Parser do
  @moduledoc """
  Per-agent transcript-parser dispatch (Task 86).

  Walks the raw Port bytes captured from a headless coding-agent run into a
  unified event vocabulary Task 87's `<.transcript_view>` component renders as
  chat-style turns.

  ## Dispatch

  `init_state/1` and `append/3` are keyed on an `agent_kind` atom matching
  `Harness.AgentRegistry.agents/0`:

      :claude       => Parser.Claude       — NDJSON, claude `--output-format stream-json`
      :codex        => Parser.Codex        — NDJSON, codex `--json` mode
      :cursor       => Parser.Cursor       — NDJSON, cursor `--output-format stream-json`
      :pi           => Parser.Pi           — NDJSON, pi `--mode json`
      :grok         => Parser.Grok         — NDJSON, grok `--output-format streaming-json`
      :antigravity  => Parser.Passthrough  — free-form text (agy emits no JSON)

  Each agent parser is its own module under `Harness.Dashboard.Transcript.Parser.*`
  and owns its own per-line buffering. The dispatcher is a thin pattern-match
  table; adding a new adapter is one clause.

  ## Wire-format note vs. Task 86 body

  Task 86 originally grouped `:grok / :pi / :antigravity` as passthrough on
  the assumption all three emit free-form text. Captured fixtures from real
  harness runs (`test/fixtures/transcripts/`) show that Pi (`pi -p --mode json`)
  and Grok (`grok -p --output-format streaming-json`) actually emit
  structured NDJSON — Pi an Anthropic-shaped `message_update` stream, Grok a
  token-delta stream with `{"type":"thought"|"text","data":<fragment>}`
  events. The implementation honors what the wire actually does: structured
  parsers for Pi and Grok, passthrough reserved for Antigravity (which
  matches `docs/agent-cli-reference.md`'s "plain text, no `--json`" line).

  ## Unified event vocabulary

  Every parser emits a list of events drawn from this six-tag tuple set:

      {:assistant_text,     %{text: String.t()}}
      {:assistant_tool_use, %{id: String.t(), name: String.t(), input: map()}}
      {:tool_result,        %{tool_use_id: String.t(), content: term()}}
      {:system,             %{kind: atom(), data: map()}}
      {:plain_text,         %{text: String.t()}}
      {:unknown,            %{raw: String.t()}}

  Renderers walk the list in arrival order. Unknown / malformed lines are
  preserved (`:unknown, %{raw: line}`) — never silently dropped, never crash.

  ## Pure

  No GenServer, no IO, no side effects. Parser state is opaque per agent
  (each parser declares its own type alias); callers pass it through verbatim.
  Tested directly by feeding fixture bytes — including mid-line splits — and
  asserting the emitted sequence.
  """

  alias Harness.Dashboard.Transcript.Parser.Claude
  alias Harness.Dashboard.Transcript.Parser.Codex
  alias Harness.Dashboard.Transcript.Parser.Cursor
  alias Harness.Dashboard.Transcript.Parser.Grok
  alias Harness.Dashboard.Transcript.Parser.Passthrough
  alias Harness.Dashboard.Transcript.Parser.Pi

  @typedoc "Agent atom keys mirror `Harness.AgentRegistry.agents/0`."
  @type agent_kind :: :claude | :codex | :cursor | :grok | :pi | :antigravity

  @typedoc "Parser-specific opaque state. The dispatcher never inspects it."
  @type parser_state :: term()

  @typedoc "One normalized transcript event emitted upward to Task 87's renderer."
  @type event ::
          {:assistant_text, %{text: String.t()}}
          | {:assistant_tool_use, %{id: String.t(), name: String.t(), input: map()}}
          | {:tool_result, %{tool_use_id: String.t(), content: term()}}
          | {:system, %{kind: atom(), data: map()}}
          | {:plain_text, %{text: String.t()}}
          | {:unknown, %{raw: String.t()}}

  @doc """
  Returns a fresh parser state for `agent_kind`.

  Raises `ArgumentError` for an unsupported agent — adding a new adapter to
  `Harness.AgentRegistry` requires a matching dispatch clause here.
  """
  @spec init_state(agent_kind()) :: parser_state()
  def init_state(:claude), do: Claude.new()
  def init_state(:codex), do: Codex.new()
  def init_state(:cursor), do: Cursor.new()
  def init_state(:pi), do: Pi.new()
  def init_state(:grok), do: Grok.new()
  def init_state(:antigravity), do: Passthrough.new()

  def init_state(other) do
    raise ArgumentError, "unsupported agent_kind: #{inspect(other)}"
  end

  @doc """
  Feeds a `chunk` of raw Port bytes for `agent_kind` through its parser.

  Returns `{events, new_state}` — events in arrival order, state threaded so
  partial-line bytes carry into the next chunk. Pure; safe to call from any
  process.
  """
  @spec append(agent_kind(), iodata(), parser_state()) :: {[event()], parser_state()}
  def append(:claude, chunk, state), do: Claude.feed(state, chunk)
  def append(:codex, chunk, state), do: Codex.feed(state, chunk)
  def append(:cursor, chunk, state), do: Cursor.feed(state, chunk)
  def append(:pi, chunk, state), do: Pi.feed(state, chunk)
  def append(:grok, chunk, state), do: Grok.feed(state, chunk)
  def append(:antigravity, chunk, state), do: Passthrough.feed(state, chunk)

  @doc """
  Flushes any trailing partial-line bytes at port close.

  The structured parsers may have a buffered fragment that became a complete
  JSON object without a trailing newline (the agent process exited without
  one); this drains it. Passthrough has nothing to flush.
  """
  @spec finalize(agent_kind(), parser_state()) :: {[event()], parser_state()}
  def finalize(:claude, state), do: Claude.finalize(state)
  def finalize(:codex, state), do: Codex.finalize(state)
  def finalize(:cursor, state), do: Cursor.finalize(state)
  def finalize(:pi, state), do: Pi.finalize(state)
  def finalize(:grok, state), do: Grok.finalize(state)
  def finalize(:antigravity, state), do: Passthrough.finalize(state)
end
