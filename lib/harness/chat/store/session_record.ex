defmodule Harness.Chat.Store.SessionRecord do
  @moduledoc false

  @typedoc "Rehydration payload for `Harness.Chat.Session` — the result of loading a persisted chat session."
  @type t :: %__MODULE__{
          session_id: String.t(),
          messages: [map()],
          updated_at: DateTime.t()
        }

  @enforce_keys [:session_id, :messages, :updated_at]
  defstruct [:session_id, :messages, :updated_at]
end
