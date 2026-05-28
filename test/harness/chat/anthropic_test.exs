defmodule Harness.Chat.AnthropicTest do
  use ExUnit.Case, async: false

  alias Harness.Chat.Anthropic

  setup context do
    Req.Test.set_req_test_from_context(context)
    Req.Test.verify_on_exit!(context)
    :ok
  end

  describe "stream/3" do
    test "streams text deltas from Anthropic SSE chunks" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/messages"

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Req.Test.text("""
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-opus-4-7","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":8,"output_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":3}}

        event: message_stop
        data: {"type":"message_stop"}

        """)
      end)

      callback = fn event ->
        send(self(), {:stream_event, event})
        :ok
      end

      assert {:ok, %{stop_reason: "end_turn", content: [%{type: "text", text: "Hello"}]}} =
               Anthropic.stream(
                 %{messages: [%{role: :user, content: "Say hello"}]},
                 callback,
                 api_key: "test-key",
                 req_options: [plug: {Req.Test, __MODULE__}]
               )

      assert_received {:stream_event, {:text_delta, "Hel"}}
      assert_received {:stream_event, {:text_delta, "lo"}}
      assert_received {:stream_event, :done}
    end

    test "formats tool-use turns and caches static system and tool content" do
      test_pid = self()

      Req.Test.expect(__MODULE__, fn conn ->
        body = conn |> Req.Test.raw_body() |> IO.iodata_to_binary() |> Jason.decode!()
        send(test_pid, {:request_body, body})

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Req.Test.text("""
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_2","type":"message","role":"assistant","content":[],"model":"claude-opus-4-7","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":20,"output_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_2","name":"lookup","input":{}}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"query\\":"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\\"weather\\"}"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":10}}

        event: message_stop
        data: {"type":"message_stop"}

        """)
      end)

      callback = fn event ->
        send(test_pid, {:stream_event, event})
        :ok
      end

      tools = [
        %{
          name: "lookup",
          description: "Lookup a value.",
          input_schema: %{
            type: "object",
            properties: %{query: %{type: "string"}},
            required: ["query"]
          }
        }
      ]

      request = %{
        system: "Static chat rules.",
        tools: tools,
        messages: [
          %{
            role: :assistant,
            content: [Anthropic.tool_use("toolu_1", "lookup", %{"query" => "weather"})]
          },
          %{role: :user, content: [Anthropic.tool_result("toolu_1", "sunny")]}
        ]
      }

      assert {:ok, %{stop_reason: "tool_use"}} =
               Anthropic.stream(request, callback,
                 api_key: "test-key",
                 req_options: [plug: {Req.Test, __MODULE__}]
               )

      assert_received {:request_body, body}

      assert body["system"] == [
               %{
                 "type" => "text",
                 "text" => "Static chat rules.",
                 "cache_control" => %{"type" => "ephemeral"}
               }
             ]

      assert [tool] = body["tools"]
      assert tool["name"] == "lookup"
      assert tool["cache_control"] == %{"type" => "ephemeral"}

      assert [
               %{
                 "role" => "assistant",
                 "content" => [
                   %{
                     "type" => "tool_use",
                     "id" => "toolu_1",
                     "name" => "lookup",
                     "input" => %{"query" => "weather"}
                   }
                 ]
               },
               %{
                 "role" => "user",
                 "content" => [
                   %{"type" => "tool_result", "tool_use_id" => "toolu_1", "content" => "sunny"}
                 ]
               }
             ] = body["messages"]

      assert_received {:stream_event, {:tool_use, %{id: "toolu_2", input: %{"query" => "weather"}, name: "lookup"}}}
    end

    test "retries 429 rate limits after Retry-After before streaming" do
      test_pid = self()

      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(429)
        |> Plug.Conn.put_resp_header("retry-after", "2")
        |> Req.Test.json(%{
          type: "error",
          error: %{type: "rate_limit_error", message: "Too many requests"},
          request_id: "req_rate_limited"
        })
      end)

      Req.Test.expect(__MODULE__, fn conn ->
        send(test_pid, {:retried, conn.method})

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Req.Test.text("""
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_3","type":"message","role":"assistant","content":[],"model":"claude-opus-4-7","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":8,"output_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":2}}

        event: message_stop
        data: {"type":"message_stop"}

        """)
      end)

      sleep = fn delay_ms ->
        send(test_pid, {:sleep, delay_ms})
        :ok
      end

      assert {:ok, %{content: [%{type: "text", text: "ok"}]}} =
               Anthropic.stream(
                 %{messages: [%{role: :user, content: "hi"}]},
                 fn _event -> :ok end,
                 api_key: "test-key",
                 req_options: [plug: {Req.Test, __MODULE__}],
                 sleep: sleep
               )

      assert_received {:sleep, 2000}
      assert_received {:retried, "POST"}
    end

    test "returns a structured error when the API key is missing" do
      assert {:error, %{type: :missing_api_key, message: message}} =
               Anthropic.stream(%{messages: []}, fn _event -> :ok end, api_key: nil)

      assert message =~ "ANTHROPIC_API_KEY"
    end

    test "uses ANTHROPIC_API_KEY from the environment and accepts a model override" do
      test_pid = self()
      previous_api_key = System.get_env("ANTHROPIC_API_KEY")

      System.put_env("ANTHROPIC_API_KEY", "env-test-key")

      on_exit(fn ->
        if previous_api_key do
          System.put_env("ANTHROPIC_API_KEY", previous_api_key)
        else
          System.delete_env("ANTHROPIC_API_KEY")
        end
      end)

      Req.Test.expect(__MODULE__, fn conn ->
        body = conn |> Req.Test.raw_body() |> IO.iodata_to_binary() |> Jason.decode!()
        send(test_pid, {:request, conn.req_headers, body})

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Req.Test.text("""
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_4","type":"message","role":"assistant","content":[],"model":"claude-sonnet-test","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":8,"output_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":2}}

        event: message_stop
        data: {"type":"message_stop"}

        """)
      end)

      assert {:ok, %{model: "claude-sonnet-test"}} =
               Anthropic.stream(
                 %{messages: [%{role: :user, content: "hi"}]},
                 fn _event -> :ok end,
                 model: "claude-sonnet-test",
                 req_options: [plug: {Req.Test, __MODULE__}]
               )

      assert_received {:request, headers, body}
      assert {"x-api-key", "env-test-key"} in headers
      assert body["model"] == "claude-sonnet-test"
    end
  end
end
