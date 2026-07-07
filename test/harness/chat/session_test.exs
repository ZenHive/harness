defmodule Harness.Chat.SessionTest do
  # async: false because cleanup kills all sessions in the global Chat.Registry.
  use ExUnit.Case, async: false

  alias Harness.Chat.FunBackend
  alias Harness.Chat.Session
  alias Harness.Chat.Store
  alias Harness.Chat.Stream
  alias Harness.Chat.Supervisor
  alias Harness.Chat.Tools

  setup do
    on_exit(fn ->
      for {session_id, _} <- Registry.select(Harness.Chat.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}]) do
        if pid = Supervisor.whereis(session_id), do: Process.exit(pid, :kill)
      end

      File.rm_rf(Path.join(System.tmp_dir!(), "harness_chats_test"))
    end)

    :ok
  end

  describe "tool-result happy path" do
    # Regression guard for the dispatch_tools accumulator refactor (Fix 3):
    # when a backend response contains multiple tool_use blocks, the tool_result
    # messages must reach the next API call in the SAME ORDER as the tool uses —
    # not reversed. The second backend call receives the full message history and
    # we assert the two tool_result entries appear in tool-use declaration order.
    test "multiple tool uses in one response are appended in declaration order" do
      parent = self()

      {:ok, agent} =
        Agent.start_link(fn ->
          [
            fn _req, _cb, _opts ->
              {:ok,
               %{
                 content: [
                   %{type: "tool_use", id: "t1", name: "project_registry-list", input: %{}},
                   %{type: "tool_use", id: "t2", name: "describe-tools", input: %{}}
                 ],
                 stop_reason: "tool_use"
               }}
            end,
            fn req, _cb, _opts ->
              send(parent, {:second_call_messages, req.messages})

              {:ok,
               %{
                 content: [%{type: "text", text: "done"}],
                 stop_reason: "end_turn"
               }}
            end
          ]
        end)

      {:ok, session_id, _pid} =
        Supervisor.start_session(
          backend: FunBackend,
          backend_opts: [fun: scripted_fun(agent)]
        )

      assert {:ok, _} = Session.user_message(session_id, "two tools")

      assert_received {:second_call_messages, messages}

      # Expected shape: [user, assistant(2 tools), tool_result(t1), tool_result(t2)]
      assert length(messages) == 4
      assert %{role: :user, content: "two tools"} = Enum.at(messages, 0)
      assert %{role: :assistant} = Enum.at(messages, 1)

      assert %{role: :user, content: [%{type: "tool_result", tool_use_id: "t1"}]} =
               Enum.at(messages, 2)

      assert %{role: :user, content: [%{type: "tool_result", tool_use_id: "t2"}]} =
               Enum.at(messages, 3)
    end

    test "user message → tool call → result → agent final response" do
      {:ok, agent} =
        Agent.start_link(fn ->
          [
            fn _req, _cb, _opts ->
              {:ok,
               %{
                 content: [
                   %{type: "tool_use", id: "toolu_1", name: "project_registry-list", input: %{}}
                 ],
                 stop_reason: "tool_use"
               }}
            end,
            fn _req, cb, _opts ->
              cb.({:text_delta, "All "})
              cb.({:text_delta, "done."})

              {:ok,
               %{
                 content: [%{type: "text", text: "All done."}],
                 stop_reason: "end_turn"
               }}
            end
          ]
        end)

      {:ok, session_id, _pid} =
        Supervisor.start_session(
          backend: FunBackend,
          backend_opts: [fun: scripted_fun(agent)]
        )

      assert :ok = Stream.subscribe(session_id)

      assert {:ok, %{stop_reason: "end_turn"}} = Session.user_message(session_id, "List projects")

      assert_received {:harness_chat_stream, ^session_id, %{type: "text_delta", text: "All "}}
      assert_received {:harness_chat_stream, ^session_id, %{type: "tool_result", id: "toolu_1"}}
      assert_received {:harness_chat_stream, ^session_id, %{type: "done", response: _}}
    end
  end

  describe "max_iterations abort" do
    test "aborts when the backend keeps requesting tools" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      always_tool = fn _req, _cb, _opts ->
        n = Agent.get_and_update(counter, &{&1, &1 + 1})

        {:ok,
         %{
           content: [
             %{
               type: "tool_use",
               id: "toolu_#{n}",
               name: "project_registry-list",
               input: %{"n" => n}
             }
           ],
           stop_reason: "tool_use"
         }}
      end

      {:ok, session_id, _pid} =
        Supervisor.start_session(
          backend: FunBackend,
          backend_opts: [fun: always_tool],
          max_iterations: 2
        )

      assert {:error, %{type: :terminal, reason: :max_iterations}} =
               Session.user_message(session_id, "Loop forever")
    end
  end

  describe "unknown tool" do
    test "returns structured terminal on unknown tool name" do
      bad_tool = fn _req, _cb, _opts ->
        {:ok,
         %{
           content: [
             %{type: "tool_use", id: "toolu_x", name: "not_a_real_tool", input: %{}}
           ],
           stop_reason: "tool_use"
         }}
      end

      {:ok, session_id, _pid} =
        Supervisor.start_session(backend: FunBackend, backend_opts: [fun: bad_tool])

      assert {:error, %{type: :terminal, reason: :unknown_tool, message: message}} =
               Session.user_message(session_id, "Call missing tool")

      assert message =~ "not_a_real_tool"
    end
  end

  describe "schema validation failure" do
    test "rejects tool arguments that fail JSON Schema validation" do
      invalid_args = fn _req, _cb, _opts ->
        {:ok,
         %{
           content: [
             %{
               type: "tool_use",
               id: "toolu_bad",
               name: "roadmap-ingest",
               input: %{}
             }
           ],
           stop_reason: "tool_use"
         }}
      end

      {:ok, session_id, _pid} =
        Supervisor.start_session(backend: FunBackend, backend_opts: [fun: invalid_args])

      assert {:error, %{type: :terminal, reason: :schema_validation_failed}} =
               Session.user_message(session_id, "Bad ingest args")
    end
  end

  describe "loop detection" do
    test "aborts on repeated identical tool calls within one turn chain" do
      {:ok, agent} =
        Agent.start_link(fn ->
          [
            fn _req, _cb, _opts ->
              {:ok,
               %{
                 content: [
                   %{type: "tool_use", id: "toolu_a", name: "project_registry-list", input: %{}}
                 ],
                 stop_reason: "tool_use"
               }}
            end,
            fn _req, _cb, _opts ->
              {:ok,
               %{
                 content: [
                   %{type: "tool_use", id: "toolu_b", name: "project_registry-list", input: %{}}
                 ],
                 stop_reason: "tool_use"
               }}
            end
          ]
        end)

      {:ok, session_id, _pid} =
        Supervisor.start_session(
          backend: FunBackend,
          backend_opts: [fun: scripted_fun(agent)]
        )

      assert {:error, %{type: :terminal, reason: :loop_detected, message: message}} =
               Session.user_message(session_id, "Repeat yourself")

      assert message =~ "project_registry-list"
    end
  end

  describe "max_history_bytes" do
    test "aborts when conversation history exceeds the byte cap" do
      done = fn _req, _cb, _opts ->
        {:ok, %{content: [%{type: "text", text: "ok"}], stop_reason: "end_turn"}}
      end

      {:ok, session_id, _pid} =
        Supervisor.start_session(
          backend: FunBackend,
          backend_opts: [fun: done],
          max_history_bytes: 32
        )

      assert {:error, %{type: :terminal, reason: :max_history_bytes}} =
               Session.user_message(session_id, String.duplicate("x", 128))
    end
  end

  describe "terminal broadcasts to the session stream" do
    # Review fix #6: loop_detected / backend_error / max_history_bytes used to
    # build their terminals inline and return without broadcasting, so a
    # stream-only subscriber never saw them. They now route through a single
    # broadcast helper — assert each reaches the stream exactly once.
    test "loop_detected is broadcast to subscribers, not only returned" do
      {:ok, agent} =
        Agent.start_link(fn ->
          tool = fn _req, _cb, _opts ->
            {:ok,
             %{
               content: [%{type: "tool_use", id: "t", name: "project_registry-list", input: %{}}],
               stop_reason: "tool_use"
             }}
          end

          [tool, tool]
        end)

      {:ok, session_id, _pid} =
        Supervisor.start_session(backend: FunBackend, backend_opts: [fun: scripted_fun(agent)])

      assert :ok = Stream.subscribe(session_id)

      assert {:error, %{type: :terminal, reason: :loop_detected}} =
               Session.user_message(session_id, "loop")

      assert_received {:harness_chat_stream, ^session_id, %{type: :terminal, reason: :loop_detected}}
    end

    test "backend_error is broadcast to subscribers, not only returned" do
      boom = fn _req, _cb, _opts -> {:error, %{message: "backend exploded"}} end

      {:ok, session_id, _pid} =
        Supervisor.start_session(backend: FunBackend, backend_opts: [fun: boom])

      assert :ok = Stream.subscribe(session_id)

      assert {:error, %{type: :terminal, reason: :backend_error}} =
               Session.user_message(session_id, "trigger error")

      assert_received {:harness_chat_stream, ^session_id, %{type: :terminal, reason: :backend_error}}
    end

    test "max_history_bytes is broadcast to subscribers, not only returned" do
      done = fn _req, _cb, _opts ->
        {:ok, %{content: [%{type: "text", text: "ok"}], stop_reason: "end_turn"}}
      end

      {:ok, session_id, _pid} =
        Supervisor.start_session(
          backend: FunBackend,
          backend_opts: [fun: done],
          max_history_bytes: 32
        )

      assert :ok = Stream.subscribe(session_id)

      assert {:error, %{type: :terminal, reason: :max_history_bytes}} =
               Session.user_message(session_id, String.duplicate("x", 128))

      assert_received {:harness_chat_stream, ^session_id, %{type: :terminal, reason: :max_history_bytes}}
    end

    test ":busy is broadcast to subscribers, not only returned" do
      test_pid = self()
      {:ok, gate} = Agent.start_link(fn -> false end)

      parking = fn _req, _cb, _opts ->
        Agent.update(gate, fn _ ->
          send(test_pid, :turn_started)
          true
        end)

        receive do
          :harness_cancel -> {:ok, %{content: [%{type: "text", text: "done"}], stop_reason: "end_turn"}}
        after
          5_000 -> {:error, %{message: "test timeout"}}
        end
      end

      {:ok, session_id, _pid} =
        Supervisor.start_session(backend: FunBackend, backend_opts: [fun: parking])

      assert :ok = Stream.subscribe(session_id)

      turn = Task.async(fn -> Session.user_message(session_id, "first", 10_000) end)
      assert_receive :turn_started, 2_000

      assert {:error, %{type: :terminal, reason: :busy, message: message}} =
               Session.user_message(session_id, "second", 5_000)

      assert message =~ "already processing"

      assert_received {:harness_chat_stream, ^session_id, %{type: :terminal, reason: :busy}}

      assert :ok = Session.cancel(session_id)
      assert {:ok, _} = Task.await(turn, 5_000)
    end
  end

  describe "idle reap" do
    test "an idle session terminates after idle_timeout and rehydrates on ensure_session" do
      done = fn _req, _cb, _opts ->
        {:ok, %{content: [%{type: "text", text: "ack"}], stop_reason: "end_turn"}}
      end

      id = "idle-reap-#{System.unique_integer([:positive])}"
      opts = [id: id, backend: FunBackend, backend_opts: [fun: done], idle_timeout: 100]

      {:ok, ^id, pid} = Supervisor.start_session(opts)
      assert {:ok, _} = Session.user_message(id, "remember me")
      assert Process.alive?(pid)

      Process.sleep(200)
      refute Supervisor.whereis(id)

      noop = fn _, _, _ -> {:ok, %{content: [], stop_reason: "end_turn"}} end
      {:ok, ^id, new_pid} = Supervisor.ensure_session(opts)
      refute new_pid == pid

      assert {:ok, messages} = Session.snapshot(id)
      assert Enum.any?(messages, &match?(%{role: :user, content: "remember me"}, &1))
    end

    test "idle timer is not armed while a turn is in flight" do
      parking = fn _req, _cb, _opts ->
        receive do
          :harness_cancel -> {:ok, %{content: [], stop_reason: "end_turn"}}
        after
          5_000 -> {:error, %{message: "test timeout"}}
        end
      end

      id = "idle-busy-#{System.unique_integer([:positive])}"
      opts = [id: id, backend: FunBackend, backend_opts: [fun: parking], idle_timeout: 50]

      {:ok, ^id, pid} = Supervisor.start_session(opts)
      turn = Task.async(fn -> Session.user_message(id, "hold", 10_000) end)

      Process.sleep(150)
      assert Process.alive?(pid)

      assert :ok = Session.cancel(id)
      assert {:ok, _} = Task.await(turn, 5_000)

      Process.sleep(150)
      refute Supervisor.whereis(id)
    end
  end

  describe "cancel/1" do
    test "interrupts an in-flight turn and broadcasts a :cancelled terminal" do
      # Backend that streams one chunk then parks in the same `:harness_cancel`
      # receive contract Harness.Chat.Claude's Port drive loop implements. It
      # runs inside the session process, so Session.cancel/1's send/2 lands here.
      parking = fn _req, cb, _opts ->
        cb.({:text_delta, "thinking…"})

        receive do
          :harness_cancel -> {:error, %{type: :cancelled, message: "Turn cancelled by operator"}}
        after
          5_000 -> {:ok, %{content: [%{type: "text", text: "too late"}], stop_reason: "end_turn"}}
        end
      end

      {:ok, session_id, _pid} =
        Supervisor.start_session(backend: FunBackend, backend_opts: [fun: parking])

      assert :ok = Stream.subscribe(session_id)

      task = Task.async(fn -> Session.user_message(session_id, "hi", 10_000) end)

      # Confirm the turn is streaming before we cancel.
      assert_receive {:harness_chat_stream, ^session_id, %{type: "text_delta"}}, 2_000

      assert :ok = Session.cancel(session_id)

      assert_receive {:harness_chat_stream, ^session_id, %{type: :terminal, reason: :cancelled}}, 2_000
      assert {:error, %{type: :terminal, reason: :cancelled}} = Task.await(task)

      # History preserved: the session is still alive and the user turn remains.
      assert {:ok, messages} = Session.snapshot(session_id)
      assert Enum.any?(messages, &match?(%{role: :user, content: "hi"}, &1))
    end

    test "is a no-op on an idle session (leaves it alive)" do
      noop = fn _, _, _ -> {:ok, %{content: [], stop_reason: "end_turn"}} end
      {:ok, session_id, pid} = Supervisor.start_session(backend: FunBackend, backend_opts: [fun: noop])

      assert :ok = Session.cancel(session_id)
      assert Process.alive?(pid)
      # Still usable after an idle cancel.
      assert {:ok, _} = Session.user_message(session_id, "still here")
    end

    test "is a no-op on an unknown session id" do
      assert :ok = Session.cancel("nonexistent-#{System.unique_integer([:positive])}")
    end
  end

  describe "supervision" do
    test "start_session registers a session under Harness.Chat.Registry" do
      noop = fn _, _, _ -> {:ok, %{content: [], stop_reason: "end_turn"}} end

      assert {:ok, session_id, pid} =
               Supervisor.start_session(backend: FunBackend, backend_opts: [fun: noop])

      assert Process.alive?(pid)
      assert Supervisor.whereis(session_id) == pid
    end

    test "session crash does not affect a sibling session" do
      crash = fn _req, _cb, _opts ->
        raise "backend crash"
      end

      {:ok, stable_id, stable_pid} =
        Supervisor.start_session(
          backend: FunBackend,
          backend_opts: [fun: fn _, _, _ -> {:ok, %{content: [], stop_reason: "end_turn"}} end]
        )

      {:ok, crash_id, crash_pid} =
        Supervisor.start_session(backend: FunBackend, backend_opts: [fun: crash])

      assert catch_exit(Session.user_message(crash_id, "boom", 5_000))
      refute Process.alive?(crash_pid)

      assert Process.alive?(stable_pid)
      assert {:ok, _} = Session.user_message(stable_id, "still here")
    end
  end

  describe "Harness.Chat.Tools" do
    test "dispatch validates schema before apply/3" do
      registry = Tools.build()

      assert {:ok, _projects} = Tools.dispatch(registry, "project_registry-list", %{})

      assert {:error, {:schema_validation_failed, _errors}} =
               Tools.dispatch(registry, "roadmap-ingest", %{})
    end
  end

  defp scripted_fun(agent) do
    fn request, callback, opts ->
      step =
        Agent.get_and_update(agent, fn
          [current | rest] -> {current, rest}
          [] -> raise "script exhausted for request #{inspect(request)}"
        end)

      step.(request, callback, opts)
    end
  end

  describe "Harness.Chat.Supervisor (coverage for start_link/whereis/already_started paths)" do
    test "start_session with explicit duplicate id returns the existing pid (already_started branch)" do
      noop = fn _, _, _ -> {:ok, %{content: [], stop_reason: "end_turn"}} end

      {:ok, _id, pid1} = Supervisor.start_session(id: "dup-cover-1", backend: FunBackend, backend_opts: [fun: noop])
      {:ok, _id, pid2} = Supervisor.start_session(id: "dup-cover-1", backend: FunBackend, backend_opts: [fun: noop])

      assert pid1 == pid2
      assert Supervisor.whereis("dup-cover-1") == pid1
    end

    test "ensure_session/1 returns an existing pid without spawning a duplicate" do
      noop = fn _, _, _ -> {:ok, %{content: [], stop_reason: "end_turn"}} end
      opts = [id: "ensure-cover-1", backend: FunBackend, backend_opts: [fun: noop]]

      {:ok, _id, pid1} = Supervisor.start_session(opts)
      {:ok, _id, pid2} = Supervisor.ensure_session(opts)

      assert pid1 == pid2
    end
  end

  describe "Harness.Chat.Supervisor.list_sessions/0" do
    test "enumerates currently-live session ids" do
      noop = fn _, _, _ -> {:ok, %{content: [], stop_reason: "end_turn"}} end
      id_a = "list-cover-a-#{System.unique_integer([:positive])}"
      id_b = "list-cover-b-#{System.unique_integer([:positive])}"

      {:ok, ^id_a, _} = Supervisor.start_session(id: id_a, backend: FunBackend, backend_opts: [fun: noop])
      {:ok, ^id_b, _} = Supervisor.start_session(id: id_b, backend: FunBackend, backend_opts: [fun: noop])

      ids = Supervisor.list_sessions()
      assert id_a in ids
      assert id_b in ids
    end
  end

  describe "persistence (Task 93)" do
    test "a completed turn is persisted to the store" do
      id = "persist-#{System.unique_integer([:positive])}"

      fun = fn _req, _cb, _opts -> {:ok, %{content: [%{type: "text", text: "ack"}], stop_reason: "end_turn"}} end
      {:ok, ^id, _pid} = Supervisor.start_session(id: id, backend: FunBackend, backend_opts: [fun: fun])

      {:ok, _} = Session.user_message(id, "persist this turn")

      # Session.init/handle_call use the config'd test store root; load with no
      # opts reads that same root.
      assert {:ok, %{messages: messages}} = Store.load(id)
      assert Enum.any?(messages, &match?(%{role: :user, content: "persist this turn"}, &1))
    end

    test "a new session rehydrates a previously-saved transcript on init" do
      id = "rehydrate-#{System.unique_integer([:positive])}"
      saved = [%{role: :user, content: "remembered across restart"}]

      # Simulate a prior BEAM having persisted this session, then start a fresh
      # GenServer under the same id — init/1 should load the saved messages.
      :ok = Store.save(id, saved)

      noop = fn _, _, _ -> {:ok, %{content: [], stop_reason: "end_turn"}} end
      {:ok, ^id, _pid} = Supervisor.start_session(id: id, backend: FunBackend, backend_opts: [fun: noop])

      assert {:ok, ^saved} = Session.snapshot(id)
    end
  end
end
