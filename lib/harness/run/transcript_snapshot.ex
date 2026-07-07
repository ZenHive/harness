defmodule Harness.Run.TranscriptSnapshot do
  @moduledoc false

  @enforce_keys [:events, :seq]
  defstruct [:events, :agent_kind, :seq]

  @type t :: %__MODULE__{
          events: [{atom(), map()}],
          agent_kind: atom() | nil,
          seq: non_neg_integer()
        }

  @doc false
  @spec buffer_only(binary(), non_neg_integer()) :: %{buffer: binary(), seq: non_neg_integer()}
  def buffer_only(buffer, seq), do: %{buffer: buffer, seq: seq}
end
