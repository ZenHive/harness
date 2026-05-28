defmodule Harness.Chat.Anthropic do
  @moduledoc """
  Direct Anthropic Messages API backend for interactive chat sessions.

  This backend uses Req against `/v1/messages` with SSE streaming enabled. It
  formats Anthropic system prompts, tools, `tool_use`, and `tool_result` blocks,
  then emits normalized stream events through the callback supplied by
  `Harness.Chat.Backend`.
  """

  @behaviour Harness.Chat.Backend

  alias Harness.Chat.Backend

  @anthropic_version "2023-06-01"
  @api_url "https://api.anthropic.com/v1/messages"
  @default_model "claude-opus-4-7"
  @default_max_tokens 4096
  @default_max_retries 2
  @retry_base_delay_ms 500
  @max_retry_delay_ms 30_000
  @milliseconds_per_second 1000

  @typedoc "A normalized successful assistant response."
  @type response :: %{
          required(:role) => String.t(),
          required(:content) => [map()],
          optional(:type) => String.t(),
          optional(:id) => String.t(),
          optional(:model) => String.t(),
          optional(:stop_reason) => String.t() | nil,
          optional(:usage) => map()
        }

  @doc """
  Streams one Anthropic Messages API request.
  """
  @impl Backend
  @spec stream(Backend.request(), Backend.stream_callback(), keyword()) ::
          {:ok, response()} | {:error, Backend.error()}
  def stream(%{messages: _messages} = request, callback, opts \\ []) when is_function(callback, 1) do
    with {:ok, api_key} <- api_key(opts) do
      body = request_body(request, opts)
      request_with_retries(body, api_key, callback, opts, 0)
    end
  end

  @doc """
  Builds an assistant `tool_use` content block.
  """
  @spec tool_use(String.t(), String.t(), map()) :: map()
  def tool_use(id, name, input) when is_binary(id) and is_binary(name) and is_map(input) do
    %{type: "tool_use", id: id, name: name, input: input}
  end

  @doc """
  Builds a user `tool_result` content block for a prior `tool_use`.
  """
  @spec tool_result(String.t(), String.t() | [map()] | map()) :: map()
  def tool_result(tool_use_id, content) when is_binary(tool_use_id) do
    %{type: "tool_result", tool_use_id: tool_use_id, content: content}
  end

  @spec api_key(keyword()) :: {:ok, String.t()} | {:error, Backend.error()}
  defp api_key(opts) do
    key =
      if Keyword.has_key?(opts, :api_key) do
        Keyword.get(opts, :api_key)
      else
        System.get_env("ANTHROPIC_API_KEY")
      end

    case key do
      key when is_binary(key) and key != "" ->
        {:ok, key}

      _missing ->
        {:error,
         %{
           type: :missing_api_key,
           message: "Set ANTHROPIC_API_KEY or pass :api_key to use Harness.Chat.Anthropic."
         }}
    end
  end

  @spec request_body(Backend.request(), keyword()) :: map()
  defp request_body(request, opts) do
    %{
      model: Keyword.get(opts, :model, Map.get(request, :model, @default_model)),
      max_tokens: Keyword.get(opts, :max_tokens, Map.get(request, :max_tokens, @default_max_tokens)),
      stream: true,
      messages: Enum.map(request.messages, &format_message/1)
    }
    |> maybe_put(:system, format_system(Map.get(request, :system)))
    |> maybe_put(:tools, format_tools(Map.get(request, :tools, [])))
  end

  @spec format_system(nil | String.t() | [map()]) :: nil | [map()]
  defp format_system(nil), do: nil
  defp format_system(""), do: nil

  defp format_system(system) when is_binary(system) do
    [%{type: "text", text: system, cache_control: %{type: "ephemeral"}}]
  end

  defp format_system(system) when is_list(system) do
    system
    |> Enum.map(&normalize_block/1)
    |> put_cache_on_last()
  end

  @spec format_tools([map()]) :: nil | [map()]
  defp format_tools([]), do: nil

  defp format_tools(tools) when is_list(tools) do
    tools
    |> Enum.map(&stringify_tool/1)
    |> put_cache_on_last()
  end

  @spec format_message(Backend.message()) :: map()
  defp format_message(%{role: role, content: content}) do
    %{role: format_role(role), content: format_content(content)}
  end

  @spec format_role(atom() | String.t()) :: String.t()
  defp format_role(role) when role in [:user, "user"], do: "user"
  defp format_role(role) when role in [:assistant, "assistant"], do: "assistant"

  @spec format_content(String.t() | [map()]) :: [map()]
  defp format_content(content) when is_binary(content), do: [%{type: "text", text: content}]
  defp format_content(content) when is_list(content), do: Enum.map(content, &normalize_block/1)

  @spec normalize_block(map() | String.t()) :: map()
  defp normalize_block(block) when is_binary(block), do: %{type: "text", text: block}

  defp normalize_block(%{type: "text", text: _text} = block), do: block
  defp normalize_block(%{type: "tool_use", id: _id, name: _name, input: _input} = block), do: block
  defp normalize_block(%{type: "tool_result", tool_use_id: _id, content: _content} = block), do: block
  defp normalize_block(%{"type" => _type} = block), do: block

  @spec stringify_tool(map()) :: map()
  defp stringify_tool(tool), do: tool

  @spec put_cache_on_last([map()]) :: [map()]
  defp put_cache_on_last([]), do: []

  defp put_cache_on_last(items) do
    List.update_at(items, -1, &Map.put(&1, :cache_control, %{type: "ephemeral"}))
  end

  @spec maybe_put(map(), atom(), nil | term()) :: map()
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @spec request_with_retries(map(), String.t(), Backend.stream_callback(), keyword(), non_neg_integer()) ::
          {:ok, response()} | {:error, Backend.error()}
  defp request_with_retries(body, api_key, callback, opts, attempt) do
    case do_request(body, api_key, callback, opts) do
      {:retry, error} ->
        max_retries = Keyword.get(opts, :max_retries, @default_max_retries)

        if attempt < max_retries do
          delay_ms = retry_delay_ms(error, opts, attempt)
          sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
          sleep.(delay_ms)
          request_with_retries(body, api_key, callback, opts, attempt + 1)
        else
          {:error, Map.put(error, :retry_after_ms, retry_delay_ms(error, opts, attempt))}
        end

      other ->
        other
    end
  end

  @spec do_request(map(), String.t(), Backend.stream_callback(), keyword()) ::
          {:ok, response()} | {:error, Backend.error()} | {:retry, Backend.error()}
  defp do_request(body, api_key, callback, opts) do
    stream_ref = make_ref()

    req_opts =
      Keyword.merge(
        [
          url: @api_url,
          headers: [{"x-api-key", api_key}, {"anthropic-version", @anthropic_version}, {"accept", "text/event-stream"}],
          json: body,
          into: stream_into(stream_ref, callback),
          retry: false
        ],
        Keyword.get(opts, :req_options, [])
      )

    case Req.post(req_opts) do
      {:ok, response} -> handle_response(response, stream_ref)
      {:error, %Req.TransportError{} = error} -> {:error, transport_error(error)}
    end
  end

  @spec stream_into(reference(), Backend.stream_callback()) :: function()
  defp stream_into(stream_ref, callback) do
    fn {:data, data}, {req, response} ->
      state = response.private[stream_ref] || new_stream_state()

      state =
        if response.status == 200 do
          parse_sse_chunk(state, IO.iodata_to_binary(data), callback)
        else
          %{state | body: state.body <> IO.iodata_to_binary(data)}
        end

      response = %{response | body: "", private: Map.put(response.private, stream_ref, state)}
      {:cont, {req, response}}
    end
  end

  @spec handle_response(Req.Response.t(), reference()) ::
          {:ok, response()} | {:error, Backend.error()} | {:retry, Backend.error()}
  defp handle_response(%Req.Response{status: 200} = response, stream_ref) do
    state = response.private[stream_ref] || new_stream_state()

    case state.error do
      nil -> {:ok, assistant_response(state)}
      error -> {:error, error}
    end
  end

  defp handle_response(%Req.Response{status: status} = response, stream_ref) when status in [429, 529] do
    {:retry, response_error(response, stream_ref)}
  end

  defp handle_response(%Req.Response{} = response, stream_ref) do
    {:error, response_error(response, stream_ref)}
  end

  @spec new_stream_state() :: map()
  defp new_stream_state do
    %{
      buffer: "",
      body: "",
      blocks: %{},
      content: [],
      error: nil,
      id: nil,
      model: nil,
      role: "assistant",
      stop_reason: nil,
      usage: %{}
    }
  end

  @spec parse_sse_chunk(map(), String.t(), Backend.stream_callback()) :: map()
  defp parse_sse_chunk(state, chunk, callback) do
    {events, buffer} = split_events(state.buffer <> chunk)

    state =
      Enum.reduce(events, state, fn event, acc ->
        event
        |> decode_sse_event()
        |> handle_sse_event(acc, callback)
      end)

    %{state | buffer: buffer}
  end

  @spec split_events(String.t()) :: {[String.t()], String.t()}
  defp split_events(buffer) do
    parts = Regex.split(~r/\r?\n\r?\n/, buffer, trim: false)

    if String.ends_with?(buffer, ["\n\n", "\r\n\r\n"]) do
      {Enum.reject(parts, &(&1 == "")), ""}
    else
      {parts |> Enum.drop(-1) |> Enum.reject(&(&1 == "")), List.last(parts) || ""}
    end
  end

  @spec decode_sse_event(String.t()) :: map() | nil
  defp decode_sse_event(event) do
    event
    |> String.split(~r/\r?\n/)
    |> Enum.reduce(%{event: nil, data: []}, fn line, acc ->
      cond do
        String.starts_with?(line, "event:") ->
          %{acc | event: line |> String.replace_prefix("event:", "") |> String.trim()}

        String.starts_with?(line, "data:") ->
          data = line |> String.replace_prefix("data:", "") |> String.trim_leading()
          %{acc | data: [data | acc.data]}

        true ->
          acc
      end
    end)
    |> decode_sse_data()
  end

  @spec decode_sse_data(map()) :: map() | nil
  defp decode_sse_data(%{data: []}), do: nil

  defp decode_sse_data(%{event: event, data: data}) do
    case data |> Enum.reverse() |> Enum.join("\n") |> Jason.decode() do
      {:ok, decoded} -> Map.put(decoded, "_event", event)
      {:error, _reason} -> nil
    end
  end

  @spec handle_sse_event(nil | map(), map(), Backend.stream_callback()) :: map()
  defp handle_sse_event(nil, state, _callback), do: state

  defp handle_sse_event(%{"type" => "message_start", "message" => message}, state, callback) do
    callback.({:message_start, message})

    %{
      state
      | id: message["id"],
        model: message["model"],
        role: message["role"] || "assistant",
        usage: message["usage"] || %{}
    }
  end

  defp handle_sse_event(%{"type" => "content_block_start", "index" => index, "content_block" => block}, state, _callback) do
    block = normalize_stream_block(block)
    %{state | blocks: Map.put(state.blocks, index, block)}
  end

  defp handle_sse_event(
         %{"type" => "content_block_delta", "index" => index, "delta" => %{"type" => "text_delta", "text" => text}},
         state,
         callback
       ) do
    callback.({:text_delta, text})
    update_block(state, index, fn block -> Map.update(block, :text, text, &(&1 <> text)) end)
  end

  defp handle_sse_event(
         %{
           "type" => "content_block_delta",
           "index" => index,
           "delta" => %{"type" => "input_json_delta", "partial_json" => partial_json}
         },
         state,
         _callback
       ) do
    update_block(state, index, fn block -> Map.update(block, :input_json, partial_json, &(&1 <> partial_json)) end)
  end

  defp handle_sse_event(%{"type" => "content_block_stop", "index" => index}, state, callback) do
    case Map.fetch(state.blocks, index) do
      {:ok, %{type: "tool_use"} = block} ->
        tool_use = finalize_tool_use(block)
        callback.({:tool_use, tool_use})
        append_content(state, tool_use)

      {:ok, %{type: "text"} = block} ->
        append_content(state, Map.take(block, [:type, :text]))

      :error ->
        state
    end
  end

  defp handle_sse_event(%{"type" => "message_delta", "delta" => delta, "usage" => usage}, state, _callback) do
    %{state | stop_reason: delta["stop_reason"], usage: Map.merge(state.usage, usage || %{})}
  end

  defp handle_sse_event(%{"type" => "message_stop"}, state, callback) do
    callback.(:done)
    state
  end

  defp handle_sse_event(%{"type" => "error", "error" => error}, state, _callback) do
    %{state | error: normalize_error(200, error, nil, nil)}
  end

  defp handle_sse_event(_event, state, _callback), do: state

  @spec normalize_stream_block(map()) :: map()
  defp normalize_stream_block(%{"type" => "text", "text" => text}), do: %{type: "text", text: text}

  defp normalize_stream_block(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}) do
    %{type: "tool_use", id: id, name: name, input: input || %{}, input_json: ""}
  end

  defp normalize_stream_block(%{"type" => type}), do: %{type: type}

  @spec update_block(map(), non_neg_integer(), (map() -> map())) :: map()
  defp update_block(state, index, fun) do
    %{state | blocks: Map.update(state.blocks, index, fun.(%{}), fun)}
  end

  @spec append_content(map(), map()) :: map()
  defp append_content(state, block), do: %{state | content: state.content ++ [block]}

  @spec finalize_tool_use(map()) :: map()
  defp finalize_tool_use(%{input_json: ""} = block), do: Map.take(block, [:type, :id, :name, :input])

  defp finalize_tool_use(%{input_json: input_json} = block) do
    input =
      case Jason.decode(input_json) do
        {:ok, decoded} -> decoded
        {:error, _reason} -> block.input
      end

    %{type: "tool_use", id: block.id, name: block.name, input: input}
  end

  @spec assistant_response(map()) :: response()
  defp assistant_response(state) do
    %{
      id: state.id,
      type: "message",
      role: state.role,
      model: state.model,
      stop_reason: state.stop_reason,
      usage: state.usage,
      content: state.content
    }
  end

  @spec response_error(Req.Response.t(), reference()) :: Backend.error()
  defp response_error(response, stream_ref) do
    state = response.private[stream_ref] || new_stream_state()
    body = state.body || ""
    request_id = first_header(response, "request-id")
    retry_after_ms = retry_after_ms(response)

    error =
      case Jason.decode(body) do
        {:ok, %{"error" => error}} -> error
        _other -> %{"type" => "http_error", "message" => body}
      end

    normalize_error(response.status, error, request_id, retry_after_ms)
  end

  @spec normalize_error(non_neg_integer(), map(), nil | String.t(), nil | non_neg_integer()) ::
          Backend.error()
  defp normalize_error(status, error, request_id, retry_after_ms) do
    anthropic_type = error["type"] || "api_error"

    %{
      type: error_type(status, anthropic_type),
      status: status,
      anthropic_type: anthropic_type,
      message: error["message"] || "Anthropic API request failed.",
      request_id: request_id,
      retry_after_ms: retry_after_ms
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @spec error_type(non_neg_integer(), String.t()) :: atom()
  defp error_type(401, _type), do: :authentication_error
  defp error_type(429, _type), do: :rate_limited
  defp error_type(529, _type), do: :overloaded
  defp error_type(_status, "overloaded_error"), do: :overloaded
  defp error_type(_status, "rate_limit_error"), do: :rate_limited
  defp error_type(_status, "authentication_error"), do: :authentication_error
  defp error_type(_status, "invalid_request_error"), do: :invalid_request
  defp error_type(_status, "permission_error"), do: :permission_error
  defp error_type(_status, "not_found_error"), do: :not_found
  defp error_type(_status, "request_too_large"), do: :request_too_large
  defp error_type(_status, "timeout_error"), do: :timeout
  defp error_type(_status, _type), do: :api_error

  # Req.TransportError doesn't export an `@type t()` (it uses bare `defexception`,
  # unlike Mint.TransportError which exports `t/0`). The function only ever calls
  # `Exception.message/1` on it, so the broader `Exception.t()` is the right spec.
  @spec transport_error(Exception.t()) :: Backend.error()
  defp transport_error(error) do
    %{type: :transport_error, message: Exception.message(error)}
  end

  @spec retry_delay_ms(Backend.error(), keyword(), non_neg_integer()) :: non_neg_integer()
  defp retry_delay_ms(%{retry_after_ms: retry_after_ms}, _opts, _attempt) when is_integer(retry_after_ms) do
    retry_after_ms
  end

  defp retry_delay_ms(_error, opts, attempt) do
    base_ms = Keyword.get(opts, :retry_base_delay_ms, @retry_base_delay_ms)
    cap_ms = Keyword.get(opts, :max_retry_delay_ms, @max_retry_delay_ms)
    min(base_ms * Integer.pow(2, attempt), cap_ms)
  end

  @spec retry_after_ms(Req.Response.t()) :: nil | non_neg_integer()
  defp retry_after_ms(response) do
    response
    |> first_header("retry-after")
    |> parse_retry_after()
  end

  @spec parse_retry_after(nil | String.t()) :: nil | non_neg_integer()
  defp parse_retry_after(nil), do: nil

  defp parse_retry_after(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds * @milliseconds_per_second
      _other -> nil
    end
  end

  @spec first_header(Req.Response.t(), String.t()) :: nil | String.t()
  defp first_header(response, header) do
    response.headers
    |> Map.get(header, [])
    |> List.first()
  end
end
