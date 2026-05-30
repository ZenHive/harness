defmodule Harness.Dashboard.ChatLiveMountTest do
  @moduledoc """
  `Phoenix.LiveViewTest`-driven coverage for `Harness.Dashboard.ChatLive` — the
  live surface (`mount/3`, `handle_params/3`, the PubSub `handle_info`
  event-fan, and the composer `handle_event`s). The pure helpers
  (`append_bounded/2`, `normalize_snapshot/1`, `set_tool_result/3`, the
  function components) are covered as direct calls in
  `Harness.Dashboard.ChatLiveTest`; this module mounts the LiveView and drives
  it end-to-end.

  `async: false` — the cleanup `on_exit` kills *every* registered chat session,
  which would tear down a parallel async module's sessions mid-run.
  """

  use Harness.Dashboard.ConnCase, async: false

  alias Harness.Chat.FunBackend
  alias Harness.Chat.Session
  alias Harness.Chat.Supervisor, as: ChatSupervisor

  setup do
    on_exit(fn ->
      for {session_id, _} <- Registry.select(Harness.Chat.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}]) do
        if pid = ChatSupervisor.whereis(session_id), do: Process.exit(pid, :kill)
      end
    end)

    :ok
  end

  describe "index mount (:index action)" do
    test "mounts /harness/chat as a session index, not a redirect to a fresh session", %{conn: conn} do
      # Task 93 moved /harness/chat from :new (auto-redirect) to :index. The bare
      # URL now renders the list; minting a fresh session is the "New chat" button.
      {:ok, _view, html} = live(conn, "/harness/chat")
      assert html =~ "Chats"
      assert html =~ "New chat"
    end

    test "lists a live session with its derived label and a deep link", %{conn: conn} do
      fun = fn _req, _cb, _opts -> {:ok, %{content: [], stop_reason: "end_turn"}} end
      sid = start_fun_session(fun)
      {:ok, _} = Session.user_message(sid, "make me a sandwich")

      {:ok, _view, html} = live(conn, "/harness/chat")

      # Live session surfaces with the first-user-message label, a "live" marker,
      # the id, and a link to its deep-link URL.
      assert html =~ "make me a sandwich"
      assert html =~ sid
      assert html =~ ~s(href="/harness/chat/#{sid}")
      assert html =~ "live"
    end

    test "the New chat button mints a fresh session and navigates to it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/harness/chat")
      assert {:error, {:live_redirect, %{to: to}}} = render_click(view, "new_chat", %{})
      assert to =~ ~r"^/harness/chat/chat-[0-9a-f]+$"
    end
  end

  describe "deep-link to an existing session (:show action)" do
    test "replays the snapshot of a session that already has history", %{conn: conn} do
      fun = fn _req, cb, _opts ->
        cb.({:text_delta, "replayed-token"})
        {:ok, %{content: [%{type: "text", text: "replayed-token"}], stop_reason: "end_turn"}}
      end

      sid = start_fun_session(fun)
      {:ok, _} = Session.user_message(sid, "hello there")

      {:ok, _view, html} = live(conn, "/harness/chat/#{sid}")

      # load_snapshot {:ok, messages} (non-empty) → normalize_snapshot → render.
      assert html =~ "hello there"
      assert html =~ "replayed-token"
      assert html =~ sid
    end

    test "mounts a fresh deep link whose session does not exist yet", %{conn: conn} do
      # No session pre-started: ensure_session starts a Claude-backed one (no
      # external process until a user_message), snapshot returns the empty
      # history → empty-state branch.
      id = "chat-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      {:ok, _view, html} = live(conn, "/harness/chat/#{id}")

      assert html =~ "New chat session"
      assert html =~ id
    end
  end

  describe "streamed PubSub events (handle_info → apply_event)" do
    setup %{conn: conn} do
      sid = start_fun_session(fn _req, _cb, _opts -> {:ok, %{content: [], stop_reason: "end_turn"}} end)
      {:ok, view, _html} = live(conn, "/harness/chat/#{sid}")
      %{view: view, sid: sid}
    end

    test "drops cross-session events, then streams text + tool_call + tool_result + done", %{
      view: view,
      sid: sid
    } do
      # cross-session guard: sid mismatch → no-op clause.
      send(view.pid, {:harness_chat_stream, "other-sid", %{type: "text_delta", text: "ignored"}})
      # ensure_active + text_delta append.
      send(view.pid, {:harness_chat_stream, sid, %{type: "text_delta", text: "streamed-hello"}})
      # tool_call append.
      send(
        view.pid,
        {:harness_chat_stream, sid, %{type: "tool_call", id: "t1", name: "list_projects", arguments: %{}}}
      )

      # tool_result decode (binary JSON) + set_tool_result.
      send(view.pid, {:harness_chat_stream, sid, %{type: "tool_result", id: "t1", content: ~s({"ok":true})}})
      # done → clears :active, prune_overflow.
      send(view.pid, {:harness_chat_stream, sid, %{type: "done"}})

      html = render(view)
      assert html =~ "streamed-hello"
      assert html =~ "list_projects"
      refute html =~ "ignored"
    end

    test "a terminal event after partial streaming flushes the active turn", %{view: view, sid: sid} do
      # Seed an active assistant turn, then terminate WITHOUT a done — exercises
      # flush_active_if_any's non-nil branch and the :terminal item insert.
      send(view.pid, {:harness_chat_stream, sid, %{type: "text_delta", text: "partial-before-terminal"}})
      send(view.pid, {:harness_chat_stream, sid, %{type: :terminal, reason: :backend_error, message: "boom"}})

      html = render(view)
      assert html =~ "partial-before-terminal"
      assert html =~ "boom"
    end

    test "an unknown event type is ignored without crashing", %{view: view, sid: sid} do
      send(view.pid, {:harness_chat_stream, sid, %{type: "mystery"}})
      # Unmatched non-stream messages hit the catch-all handle_info too.
      send(view.pid, :some_unrelated_message)
      assert render(view) =~ "New chat"
    end
  end

  describe "composer events (handle_event)" do
    setup %{conn: conn} do
      sid = start_fun_session(fn _req, _cb, _opts -> {:ok, %{content: [], stop_reason: "end_turn"}} end)
      {:ok, view, _html} = live(conn, "/harness/chat/#{sid}")
      %{view: view, sid: sid}
    end

    test "input_change tracks the composer text", %{view: view} do
      view
      |> form("form.composer", %{"text" => "draft message"})
      |> render_change()

      assert render(view) =~ "draft message"
    end

    test "submitting blank text is ignored", %{view: view} do
      view
      |> form("form.composer", %{"text" => "   "})
      |> render_submit()

      # No user bubble rendered.
      refute render(view) =~ "msg msg-user"
    end

    test "submitting real text inserts the user bubble and dispatches the turn", %{view: view} do
      view
      |> form("form.composer", %{"text" => "do something useful"})
      |> render_submit()

      assert render(view) =~ "do something useful"
    end

    test "the prefill event seeds the composer from a playbook slug", %{view: view} do
      render_click(view, "prefill", %{"name" => "dispatch-single-task"})
      assert render(view) =~ "run the dispatch-single-task playbook for "
    end

    test "new_chat navigates to a fresh chat URL", %{view: view} do
      assert {:error, {:live_redirect, %{to: to}}} = render_click(view, "new_chat", %{})
      assert to =~ ~r"^/harness/chat/chat-[0-9a-f]+$"
    end
  end

  describe "streaming indicator lifecycle (Task 96)" do
    setup %{conn: conn} do
      sid = start_fun_session(fn _req, _cb, _opts -> {:ok, %{content: [], stop_reason: "end_turn"}} end)
      {:ok, view, _html} = live(conn, "/harness/chat/#{sid}")
      %{view: view, sid: sid}
    end

    test "a :terminal event clears the streaming indicator, not only :done", %{view: view, sid: sid} do
      send(view.pid, {:harness_chat_stream, sid, %{type: "text_delta", text: "thinking…"}})
      assert render(view) =~ ~s(data-streaming="true")

      # The behaviour Task 96 pins: a terminal (here a cancellation) clears the
      # cursor signal, the same as the :done path does.
      send(
        view.pid,
        {:harness_chat_stream, sid, %{type: :terminal, reason: :cancelled, message: "Turn cancelled by operator"}}
      )

      html = render(view)
      refute html =~ ~s(data-streaming="true")
      assert html =~ "Turn cancelled by operator"
    end

    test "the :done event also clears the streaming indicator", %{view: view, sid: sid} do
      send(view.pid, {:harness_chat_stream, sid, %{type: "text_delta", text: "partial"}})
      assert render(view) =~ ~s(data-streaming="true")

      send(view.pid, {:harness_chat_stream, sid, %{type: "done"}})
      refute render(view) =~ ~s(data-streaming="true")
    end
  end

  describe "stop/cancel control (Task 95)" do
    setup %{conn: conn} do
      sid = start_fun_session(fn _req, _cb, _opts -> {:ok, %{content: [], stop_reason: "end_turn"}} end)
      {:ok, view, html} = live(conn, "/harness/chat/#{sid}")
      %{view: view, sid: sid, html: html}
    end

    test "Send shows when idle; Stop replaces it once a turn is streaming", %{view: view, sid: sid, html: html} do
      # Match the button, not the `.stop-btn` CSS rule that's always in the
      # stylesheet — phx-click="cancel" appears only on the Stop button element.
      assert html =~ ">Send<"
      refute html =~ ~s(phx-click="cancel")

      send(view.pid, {:harness_chat_stream, sid, %{type: "text_delta", text: "working"}})
      streaming = render(view)
      assert streaming =~ ~s(class="stop-btn")
      assert streaming =~ ~s(phx-click="cancel")
      refute streaming =~ ">Send<"
    end

    test "clicking Stop routes through handle_event(\"cancel\", …) without crashing", %{view: view, sid: sid} do
      send(view.pid, {:harness_chat_stream, sid, %{type: "text_delta", text: "working"}})

      # The FunBackend session is idle in-test (no live turn parked), so
      # Session.cancel/1 is a no-op; assert the wiring fires and the view lives.
      view |> element("button.stop-btn") |> render_click()
      assert Process.alive?(view.pid)

      # A subsequent terminal clears the cursor and retires Stop.
      send(view.pid, {:harness_chat_stream, sid, %{type: :terminal, reason: :cancelled, message: "Stopped"}})
      html = render(view)
      refute html =~ ~s(phx-click="cancel")
      refute html =~ ~s(data-streaming="true")
    end
  end

  @spec start_fun_session((map(), (term() -> any()), keyword() -> {:ok, map()})) :: String.t()
  defp start_fun_session(fun) do
    {:ok, sid, _pid} =
      ChatSupervisor.start_session(backend: FunBackend, backend_opts: [fun: fun])

    sid
  end
end
