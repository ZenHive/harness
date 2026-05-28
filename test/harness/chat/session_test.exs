defmodule Harness.Chat.SessionTest do
  use ExUnit.Case, async: false

  alias Harness.Chat.FunBackend
  alias Harness.Chat.Session
  alias Harness.Chat.Stream
  alias Harness.Chat.Supervisor
  alias Harness.Chat.Tools

  setup do
    on_exit(fn ->
      for {session_id, _} <- Registry.select(Harness.Chat.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}]) do
        if pid = Supervisor.whereis(session_id), do: Process.exit(pid, :kill)
      end
    end)

    :ok
  end

  describe "tool-result happy path" do
    test "user message → tool call → result → agent final response" do
      {:ok, agent} =
        Agent.start_link(fn ->
          [
            fn _req, _cb, _opts ->
              {:ok,
               %{
                 content: [
                   %{type: "tool_use", id: "toolu_1", name: "project_registry__list", input: %{}}
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
               name: "project_registry__list",
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
               name: "roadmap__ingest",
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
                   %{type: "tool_use", id: "toolu_a", name: "project_registry__list", input: %{}}
                 ],
                 stop_reason: "tool_use"
               }}
            end,
            fn _req, _cb, _opts ->
              {:ok,
               %{
                 content: [
                   %{type: "tool_use", id: "toolu_b", name: "project_registry__list", input: %{}}
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

      assert message =~ "project_registry__list"
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

      assert {:ok, _projects} = Tools.dispatch(registry, "project_registry__list", %{})

      assert {:error, {:schema_validation_failed, _errors}} =
               Tools.dispatch(registry, "roadmap__ingest", %{})
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
  end
end
