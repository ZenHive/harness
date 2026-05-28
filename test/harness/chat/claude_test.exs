defmodule Harness.Chat.ClaudeTest do
  use ExUnit.Case, async: true

  alias Harness.Chat.Claude

  describe "build_argv/5" do
    test "produces the base headless command without optional flags" do
      argv = Claude.build_argv("hello world", "/tmp/mcp.json", [], nil, nil)

      assert argv == [
               "-p",
               "--output-format",
               "stream-json",
               "--verbose",
               "--permission-mode",
               "bypassPermissions",
               "--mcp-config",
               "/tmp/mcp.json",
               "hello world"
             ]
    end

    test "appends --model and --append-system-prompt when supplied" do
      argv =
        Claude.build_argv(
          "do work",
          "/tmp/mcp.json",
          [],
          "claude-opus-4-7",
          "You are the harness chat orchestrator."
        )

      assert "--model" in argv
      assert "claude-opus-4-7" in argv
      assert "--append-system-prompt" in argv
      assert "You are the harness chat orchestrator." in argv
      assert List.last(argv) == "do work"
    end

    test "threads resume_argv through before the prompt" do
      argv = Claude.build_argv("again", "/tmp/mcp.json", ["--continue"], nil, nil)
      assert "--continue" in argv
      assert List.last(argv) == "again"
    end

    test "treats an empty or nil system prompt as omitted" do
      refute "--append-system-prompt" in Claude.build_argv("p", "/tmp/m", [], nil, nil)
      refute "--append-system-prompt" in Claude.build_argv("p", "/tmp/m", [], nil, "")
    end
  end

  describe "resume_argv/1" do
    test "returns [] on the first turn (one message)" do
      assert Claude.resume_argv([%{role: :user, content: "hi"}]) == []
    end

    test "returns ['--continue'] once prior assistant content is present" do
      messages = [
        %{role: :user, content: "first"},
        %{role: :assistant, content: [%{"type" => "text", "text" => "ok"}]},
        %{role: :user, content: "second"}
      ]

      assert Claude.resume_argv(messages) == ["--continue"]
    end
  end

  describe "extract_user_text/1" do
    test "returns the latest user message body" do
      messages = [
        %{role: :user, content: "older"},
        %{role: :assistant, content: [%{"type" => "text", "text" => "ack"}]},
        %{role: :user, content: "latest"}
      ]

      assert Claude.extract_user_text(messages) == {:ok, "latest"}
    end

    test "accepts both atom and string role keys" do
      assert Claude.extract_user_text([%{"role" => "user", "content" => "hello"}]) == {:ok, "hello"}
    end

    test "errors when no user message is present" do
      assert {:error, %{type: :no_user_message}} = Claude.extract_user_text([])

      assert {:error, %{type: :no_user_message}} =
               Claude.extract_user_text([%{role: :assistant, content: []}])
    end

    test "errors when the latest user message has structured content" do
      messages = [
        %{role: :user, content: [%{type: "tool_result", tool_use_id: "x", content: "y"}]}
      ]

      assert {:error, %{type: :unsupported_user_content}} = Claude.extract_user_text(messages)
    end
  end

  describe "write_mcp_config/2" do
    @tag :tmp_dir
    test "writes a .harness-mcp-config.json file pointing at the supplied URL", %{tmp_dir: tmp_dir} do
      assert {:ok, path} = Claude.write_mcp_config(tmp_dir, "http://localhost:4018/harness/mcp")
      assert Path.basename(path) == ".harness-mcp-config.json"
      assert File.exists?(path)

      assert {:ok,
              %{
                "mcpServers" => %{
                  "harness" => %{"type" => "http", "url" => "http://localhost:4018/harness/mcp"}
                }
              }} = path |> File.read!() |> Jason.decode()
    end
  end

  describe "default_cwd/1" do
    test "is a deterministic per-session path under the OS tmp dir" do
      cwd = Claude.default_cwd("chat-deadbeef")
      assert String.starts_with?(cwd, System.tmp_dir!())
      assert String.ends_with?(cwd, "harness-chat/chat-deadbeef")
    end
  end

  describe "build_env/1" do
    test "scrubs ANTHROPIC_API_KEY by default (subscription path)" do
      env = Claude.build_env(%{})
      assert {"ANTHROPIC_API_KEY", false} in env
    end

    test "merges caller-supplied env over the scrub baseline" do
      env = Claude.build_env(%{"MY_VAR" => "1"})
      assert {"MY_VAR", "1"} in env
      assert {"ANTHROPIC_API_KEY", false} in env
    end

    test "lets an explicit caller re-set ANTHROPIC_API_KEY (caller wins)" do
      env = Claude.build_env(%{"ANTHROPIC_API_KEY" => "explicit-override"})
      assert {"ANTHROPIC_API_KEY", "explicit-override"} in env
    end
  end

  describe "stream/3 (no claude binary)" do
    @tag :tmp_dir
    test "returns :missing_session_id when backend_opts omits the session id", %{tmp_dir: _tmp_dir} do
      assert {:error, %{type: :missing_session_id}} =
               Claude.stream(
                 %{messages: [%{role: :user, content: "hi"}]},
                 fn _ -> :ok end,
                 []
               )
    end

    @tag :tmp_dir
    test "returns :no_user_message when the request has no user message", %{tmp_dir: tmp_dir} do
      assert {:error, %{type: :no_user_message}} =
               Claude.stream(
                 %{messages: []},
                 fn _ -> :ok end,
                 session_id: "chat-empty",
                 cwd: tmp_dir
               )
    end
  end
end
