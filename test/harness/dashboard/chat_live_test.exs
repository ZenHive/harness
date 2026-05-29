defmodule Harness.Dashboard.ChatLiveTest do
  # Unit tests for `Harness.Dashboard.ChatLive`. Full LiveView mount + render
  # is verified end-to-end in the browser per Task 78's acceptance criteria —
  # the standalone Endpoint is disabled in the test env
  # (`config :harness, :dashboard, enabled: false`) so a `Phoenix.LiveViewTest`
  # mount is not wired up here. The non-trivial pieces — bounded buffers,
  # snapshot normalization, tool-result merging, and the json_tree component's
  # structural rendering — are covered as direct function calls.

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Harness.Chat.FunBackend
  alias Harness.Chat.Session
  alias Harness.Chat.Supervisor, as: ChatSupervisor
  alias Harness.Dashboard.ChatLive
  alias Harness.Dashboard.Components

  setup do
    on_exit(fn ->
      for {session_id, _} <- Registry.select(Harness.Chat.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}]) do
        if pid = ChatSupervisor.whereis(session_id), do: Process.exit(pid, :kill)
      end
    end)

    :ok
  end

  describe "append_bounded/2" do
    test "appends when under the per-message byte cap" do
      assert ChatLive.append_bounded("hello", " world") == "hello world"
    end

    test "truncates and stamps the sentinel once at the cap" do
      cap = ChatLive.max_message_bytes()
      existing = String.duplicate("x", cap - 4)
      result = ChatLive.append_bounded(existing, "abcdefghij")

      assert String.ends_with?(result, "\n[…truncated]")
      # The accumulator stops exactly at the cap; "abcd" fits, "efghij" does not.
      kept = String.replace_suffix(result, "\n[…truncated]", "")
      assert byte_size(kept) == cap
    end

    test "drops further appends once already truncated" do
      already = String.duplicate("x", 8) <> "\n[…truncated]"
      assert ChatLive.append_bounded(already, "more text") == already
    end

    # Review fix #7: a streamed text_delta can land mid-codepoint. A raw
    # `binary_part/3` byte slice at the cap would split a multi-byte UTF-8
    # codepoint and yield an invalid binary LiveView refuses to render; the
    # safe prefix must trim the partial codepoint to keep the result valid.
    test "truncation never splits a multi-byte UTF-8 codepoint" do
      cap = ChatLive.max_message_bytes()
      # Leave 3 bytes of room, then append "é" (2 bytes) + "🎯" (4 bytes). A
      # raw 3-byte slice keeps "é" plus the first byte of "🎯" (invalid); the
      # safe prefix drops the partial codepoint, keeping the complete "é".
      existing = String.duplicate("x", cap - 3)
      addition = "é🎯zzzz"

      result = ChatLive.append_bounded(existing, addition)

      assert String.valid?(result)
      assert String.ends_with?(result, "\n[…truncated]")

      kept = String.replace_suffix(result, "\n[…truncated]", "")
      assert String.valid?(kept)
      assert kept == existing <> "é"
    end
  end

  describe "set_tool_result/3" do
    test "fills the result + status on the matching tool_call by id" do
      tools = [
        %{id: "toolu_a", name: "list_projects", args: %{}, result: nil, status: :pending},
        %{id: "toolu_b", name: "list_pending", args: %{}, result: nil, status: :pending}
      ]

      [%{status: :pending} = a, %{status: :done} = b] = ChatLive.set_tool_result(tools, "toolu_b", %{count: 3})

      assert a.id == "toolu_a"
      assert b.id == "toolu_b"
      assert b.result == %{count: 3}
    end

    test "leaves the list untouched when no id matches" do
      tools = [%{id: "toolu_a", name: "x", args: %{}, result: nil, status: :pending}]
      assert ChatLive.set_tool_result(tools, "missing", %{}) == tools
    end
  end

  describe "normalize_snapshot/1" do
    test "produces empty list for empty history" do
      assert ChatLive.normalize_snapshot([]) == []
    end

    test "maps a plain user message to a single user entry" do
      [entry] = ChatLive.normalize_snapshot([%{role: :user, content: "hello"}])

      assert entry.role == :user
      assert entry.text == "hello"
      assert entry.streaming? == false
      assert entry.tool_calls == []
    end

    test "collects assistant text + tool_use blocks into one entry" do
      assistant = %{
        role: :assistant,
        content: [
          %{type: "text", text: "Let me check. "},
          %{type: "tool_use", id: "toolu_1", name: "list_projects", input: %{}}
        ]
      }

      [entry] = ChatLive.normalize_snapshot([assistant])

      assert entry.role == :assistant
      assert entry.text == "Let me check. "
      assert [tool] = entry.tool_calls
      assert tool.id == "toolu_1"
      assert tool.name == "list_projects"
      assert tool.status == :pending
      assert tool.result == nil
    end

    test "merges a subsequent tool_result back into the assistant entry's tool_calls" do
      history = [
        %{
          role: :assistant,
          content: [%{type: "tool_use", id: "toolu_x", name: "list_projects", input: %{}}]
        },
        %{
          role: :user,
          content: [
            %{type: "tool_result", tool_use_id: "toolu_x", content: ~s({"projects":["harness"]})}
          ]
        }
      ]

      [entry] = ChatLive.normalize_snapshot(history)

      assert [%{id: "toolu_x", status: :done, result: %{"projects" => ["harness"]}}] = entry.tool_calls
    end

    test "passes a non-JSON tool_result string through verbatim" do
      history = [
        %{role: :assistant, content: [%{type: "tool_use", id: "t", name: "n", input: %{}}]},
        %{role: :user, content: [%{type: "tool_result", tool_use_id: "t", content: "plain text"}]}
      ]

      [entry] = ChatLive.normalize_snapshot(history)
      assert [%{result: "plain text", status: :done}] = entry.tool_calls
    end

    test "handles a multi-turn conversation in order" do
      history = [
        %{role: :user, content: "first"},
        %{role: :assistant, content: [%{type: "text", text: "ok"}]},
        %{role: :user, content: "second"},
        %{role: :assistant, content: [%{type: "text", text: "still ok"}]}
      ]

      [u1, a1, u2, a2] = ChatLive.normalize_snapshot(history)

      assert {u1.role, u1.text} == {:user, "first"}
      assert {a1.role, a1.text} == {:assistant, "ok"}
      assert {u2.role, u2.text} == {:user, "second"}
      assert {a2.role, a2.text} == {:assistant, "still ok"}
    end

    test "assigns distinct ids so the stream can dom-id each entry" do
      history = [
        %{role: :user, content: "a"},
        %{role: :assistant, content: [%{type: "text", text: "b"}]},
        %{role: :user, content: "c"}
      ]

      ids =
        history
        |> ChatLive.normalize_snapshot()
        |> Enum.map(& &1.id)

      assert ids == Enum.uniq(ids)
    end
  end

  describe "Harness.Chat.Session.snapshot/1 round-trip" do
    test "returns {:error, :not_found} when no session is registered" do
      assert {:error, :not_found} = Session.snapshot("nonexistent-#{System.unique_integer([:positive])}")
    end

    test "returns the conversation history after driving a user message" do
      single_text = fn _req, cb, _opts ->
        cb.({:text_delta, "hello back"})
        {:ok, %{content: [%{type: "text", text: "hello back"}], stop_reason: "end_turn"}}
      end

      {:ok, session_id, _pid} =
        ChatSupervisor.start_session(
          backend: FunBackend,
          backend_opts: [fun: single_text]
        )

      assert {:ok, _} = Session.user_message(session_id, "hi")
      assert {:ok, messages} = Session.snapshot(session_id)

      assert Enum.any?(messages, &match?(%{role: :user, content: "hi"}, &1))

      assert Enum.any?(messages, fn m ->
               match?(%{role: :assistant, content: [%{type: "text", text: "hello back"}]}, m)
             end)
    end
  end

  describe "json_tree rendering" do
    test "renders a map as a <dl> with one row per key" do
      html = render_component(&Components.json_tree/1, value: %{"a" => 1, "b" => "x"})

      assert html =~ ~s(<dl)
      assert html =~ ">a<"
      assert html =~ ">b<"
      assert html =~ "leaf-number"
      assert html =~ "leaf-string"
    end

    test "renders a list as an <ol>" do
      html = render_component(&Components.json_tree/1, value: [1, "two", true])

      assert html =~ "<ol"
      assert html =~ "leaf-number"
      assert html =~ "leaf-string"
      assert html =~ "leaf-bool"
    end

    test "renders nil as a typed leaf, not raw" do
      html = render_component(&Components.json_tree/1, value: nil)
      assert html =~ "leaf-nil"
      assert html =~ "null"
    end

    test "renders an empty map / empty list with an explicit marker" do
      empty_map = render_component(&Components.json_tree/1, value: %{})
      empty_list = render_component(&Components.json_tree/1, value: [])

      assert empty_map =~ "{}"
      assert empty_list =~ "[]"
    end

    test "escapes HTML-meaningful characters in string leaves" do
      html =
        render_component(&Components.json_tree/1, value: %{"x" => "<script>alert(1)</script>"})

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end
  end

  describe "tool_call rendering" do
    test "renders the <details> wrapper with the tool name and pending status" do
      html =
        render_component(&Components.tool_call/1,
          id: "toolu_1",
          name: "list_projects",
          args: %{},
          result: nil,
          status: :pending
        )

      assert html =~ ~s(<details class="tool-call")
      assert html =~ "list_projects"
      assert html =~ ~s(data-status="pending")
      # No "result" section when result is nil
      refute html =~ ">result<"
    end

    test "renders the result section when present" do
      html =
        render_component(&Components.tool_call/1,
          id: "toolu_1",
          name: "list_projects",
          args: %{},
          result: %{"projects" => ["harness"]},
          status: :done
        )

      assert html =~ ">result<"
      assert html =~ "harness"
      assert html =~ ~s(data-status="done")
    end
  end

  describe "message_row rendering" do
    test "tags the article with the role class and renders the body text" do
      html =
        render_component(&Components.message_row/1,
          dom_id: "msg-user-1",
          role: :user,
          text: "list pending tasks",
          streaming?: false,
          tool_calls: []
        )

      assert html =~ ~s(id="msg-user-1")
      assert html =~ "msg msg-user"
      assert html =~ "list pending tasks"
      assert html =~ ~s(data-streaming="false")
    end

    test "exposes the streaming cursor signal on the body when streaming?" do
      html =
        render_component(&Components.message_row/1,
          dom_id: "msg-a-1",
          role: :assistant,
          text: "partial",
          streaming?: true,
          tool_calls: []
        )

      assert html =~ ~s(data-streaming="true")
    end

    test "renders nested tool_call slots inline" do
      tool = %{id: "toolu_1", name: "list_projects", args: %{}, result: nil, status: :pending}

      html =
        render_component(&Components.message_row/1,
          dom_id: "msg-a-1",
          role: :assistant,
          text: "",
          streaming?: false,
          tool_calls: [tool]
        )

      assert html =~ "list_projects"
      assert html =~ "tool-call"
    end
  end

  describe "session_start_opts/1" do
    # Regression: an earlier revision called ChatSupervisor.start_session(id: id)
    # without :backend. Session.init/1 requires :backend via Keyword.fetch!/2, so
    # every session failed at init — but the LiveView swallows {:error, _reason}
    # silently, so the user just saw a chat panel that did nothing. Pin both the
    # backend choice AND that this exact opts shape is accepted by the
    # supervisor, so a future re-introduction of the bug fails loudly here.
    test "names a backend so Session.init/1's Keyword.fetch!(:backend) succeeds" do
      id = "test-#{System.unique_integer([:positive])}"
      opts = ChatLive.session_start_opts(id)

      assert Keyword.fetch!(opts, :backend) == Harness.Chat.Claude
      assert Keyword.fetch!(opts, :id) == id
    end

    test "the opts shape ChatLive uses actually starts a session" do
      id = "test-#{System.unique_integer([:positive])}"

      # Drive the supervisor with exactly what ensure_session/2 would pass.
      # Harness.Chat.Claude's init validates `claude` is on PATH; the FunBackend
      # double is the only way to exercise the call shape offline. We rebuild
      # the opts to swap the backend but keep the *contract* (presence of
      # :backend) under test.
      opts = Keyword.put(ChatLive.session_start_opts(id), :backend, FunBackend)

      assert {:ok, ^id, pid} = ChatSupervisor.start_session(opts)
      assert is_pid(pid)
      assert ChatSupervisor.whereis(id) == pid
    end
  end

  describe "playbook prefill" do
    test "prefill_text/1 interpolates the slug and trails with the project cue" do
      assert ChatLive.prefill_text("dispatch-single-task") ==
               "run the dispatch-single-task playbook for "
    end

    test "playbook_bar/1 renders one prefill chip per catalogued playbook" do
      html = render_component(&ChatLive.playbook_bar/1, playbooks: Harness.Playbooks.list())

      for pb <- Harness.Playbooks.list() do
        # Title is the visible label; slug rides phx-value-name so the click
        # prefills with the name playbooks__get keys on.
        assert html =~ pb.title
        assert html =~ ~s(phx-value-name="#{pb.name}")
      end

      # Click is a JS command: push the "prefill" server event (carrying
      # phx-value-name) and focus the composer so the operator can type
      # immediately without a second click.
      assert html =~ "&quot;push&quot;,{&quot;event&quot;:&quot;prefill&quot;}"
      assert html =~ "&quot;focus&quot;,{&quot;to&quot;:&quot;textarea[name=text]&quot;}"
      assert html =~ "playbook-chip"
    end

    test "playbook_bar/1 renders nothing when the catalog is empty" do
      html = render_component(&ChatLive.playbook_bar/1, playbooks: [])

      refute html =~ "playbook-bar"
      refute html =~ "playbook-chip"
    end
  end
end
