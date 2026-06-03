defmodule Harness.Dashboard.Transcript.Parser.Passthrough do
  @moduledoc """
  Passthrough parser for unstructured agents (Antigravity).

  `agy` emits free-form plain text — no per-line JSON contract, no event
  envelope. The parser does no line-buffering and no JSON decoding; each
  inbound chunk becomes exactly one `{:plain_text, %{text: chunk}}` event.

  This is the only adapter that reaches passthrough today. Pi and Grok have
  their own structured parsers despite Task 86's original "passthrough for
  grok/pi/antigravity" body, because real captures show they emit NDJSON —
  see the dispatcher moduledoc for the wire-format note.

  Empty chunks emit nothing; mid-line splits are irrelevant because there
  is no line semantics.
  """

  @behaviour Harness.Dashboard.Transcript.Parser

  alias Harness.Dashboard.Transcript.Parser

  defstruct unused: nil

  @typedoc "No state needed — passthrough parses nothing across chunks."
  @type t :: %__MODULE__{}

  @doc "Returns a fresh parser (no state to carry)."
  @impl Parser
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Emits one `:plain_text` event per non-empty chunk.
  """
  @impl Parser
  @spec feed(t(), iodata()) :: {[Parser.event()], t()}
  def feed(%__MODULE__{} = parser, chunk) do
    case IO.iodata_to_binary(chunk) do
      "" -> {[], parser}
      text -> {[{:plain_text, %{text: text}}], parser}
    end
  end

  @doc "Nothing to flush — passthrough holds no state."
  @impl Parser
  @spec finalize(t()) :: {[Parser.event()], t()}
  def finalize(%__MODULE__{} = parser), do: {[], parser}
end
