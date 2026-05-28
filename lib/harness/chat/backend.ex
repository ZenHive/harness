defmodule Harness.Chat.Backend do
  @moduledoc """
  Behaviour for low-latency chat backends used by the chat Session process.

  Backends receive one stateless chat request and stream provider events through
  the supplied callback. The Session owns conversation state, tool dispatch, and
  UI fan-out; backend modules only format provider requests and normalize stream
  events/errors.
  """

  @typedoc "A chat content block accepted by backend implementations."
  @type content_block :: map() | String.t()

  @typedoc "A single user or assistant message."
  @type message :: %{
          required(:role) => :user | :assistant | String.t(),
          required(:content) => String.t() | [content_block()]
        }

  @typedoc "A stateless chat request."
  @type request :: %{
          required(:messages) => [message()],
          optional(:system) => String.t() | [content_block()],
          optional(:tools) => [map()],
          optional(:model) => String.t(),
          optional(:max_tokens) => pos_integer()
        }

  @typedoc "Normalized stream event delivered to the Session callback."
  @type event ::
          {:text_delta, String.t()}
          | {:tool_use, map()}
          | {:message_start, map()}
          | :done

  @typedoc "A structured backend error safe to surface to chat consumers."
  @type error :: %{
          required(:type) => atom(),
          required(:message) => String.t(),
          optional(:status) => non_neg_integer(),
          optional(:anthropic_type) => String.t(),
          optional(:request_id) => String.t(),
          optional(:retry_after_ms) => non_neg_integer()
        }

  @type stream_callback :: (event() -> term())

  @doc """
  Sends a chat request and streams normalized events through `callback`.
  """
  @callback stream(request(), stream_callback(), keyword()) ::
              {:ok, map()} | {:error, error()}
end
