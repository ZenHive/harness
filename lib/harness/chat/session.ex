defmodule Harness.Chat.Session do
  @moduledoc """
  GenServer driving the multi-turn chat tool-call loop (Task 76).

  A user message triggers backend streaming; tool calls dispatch through
  `Harness.Chat.Tools` against the descripex manifest; results feed back until
  the backend returns a non-tool response or a guard aborts the loop.
  """

  use GenServer

  alias Harness.Chat.Backend
  alias Harness.Chat.Store
  alias Harness.Chat.Store.SessionRecord
  alias Harness.Chat.Stream
  alias Harness.Chat.Tools
  alias Harness.JSONSafe

  require Logger

  @registry Harness.Chat.Registry
  @default_max_iterations 16
  @default_max_history_bytes 256 * 1024
  @default_idle_timeout 1_800_000

  @typedoc "Structured terminal event broadcast when the loop aborts."
  @type terminal_reason ::
          :max_iterations
          | :max_history_bytes
          | :loop_detected
          | :unknown_tool
          | :schema_validation_failed
          | :backend_error
          | :dispatch_failed
          | :busy
          | :cancelled

  @type terminal :: %{
          required(:type) => :terminal,
          required(:reason) => terminal_reason(),
          required(:message) => String.t(),
          optional(:details) => term()
        }

  @doc "Starts a session registered under `session_id`."
  @spec start_link(String.t(), keyword()) :: GenServer.on_start()
  def start_link(session_id, opts \\ []) when is_binary(session_id) do
    GenServer.start_link(__MODULE__, {session_id, opts}, name: via(session_id))
  end

  @doc "Sends a user message and waits for the session loop to finish."
  @spec user_message(String.t(), String.t(), timeout()) :: {:ok, map()} | {:error, terminal()}
  def user_message(session_id, text, timeout \\ 60_000) when is_binary(session_id) and is_binary(text) do
    caller = self()

    case GenServer.call(via(session_id), {:submit_user_message, text, caller}, timeout) do
      {:error, %{} = terminal} ->
        {:error, terminal}

      :accepted ->
        receive do
          {:harness_chat_turn, ^caller, result} -> result
        after
          timeout -> exit({:timeout, {__MODULE__, :user_message, [session_id, text, timeout]}})
        end
    end
  end

  @doc """
  Requests cancellation of an in-flight turn.

  Forwards `:harness_cancel` to the linked turn worker when a message is in
  flight so backends that park in a `receive` (e.g. `Harness.Chat.Claude`'s Port
  drive loop) can tear down promptly. When the session is idle the signal is a
  no-op (see `handle_info/2`).

  Always returns `:ok` — cancelling an unknown or idle session is harmless. The
  prior conversation history is preserved (only the cancelled turn's partial
  assistant output is discarded).
  """
  @spec cancel(String.t()) :: :ok
  def cancel(session_id) when is_binary(session_id) do
    case Harness.Chat.Supervisor.whereis(session_id) do
      nil ->
        :ok

      pid ->
        send(pid, :harness_cancel)
        :ok
    end
  end

  @doc """
  Returns the conversation history accumulated in the session's GenServer
  state. Used by `Harness.Dashboard.ChatLive` to backfill the message stream
  when an operator reloads a deep-link URL mid-session.

  Returns `{:error, :not_found}` if no session is registered under `session_id`.
  """
  @spec snapshot(String.t()) :: {:ok, [map()]} | {:error, :not_found}
  def snapshot(session_id) when is_binary(session_id) do
    case Harness.Chat.Supervisor.whereis(session_id) do
      nil -> {:error, :not_found}
      _pid -> {:ok, GenServer.call(via(session_id), :snapshot)}
    end
  end

  @doc false
  @impl GenServer
  @spec init({String.t(), keyword()}) :: {:ok, map()}
  def init({session_id, opts}) do
    tools = Tools.build(Keyword.take(opts, [:modules, :name_style]))

    state = %{
      session_id: session_id,
      backend: Keyword.fetch!(opts, :backend),
      backend_opts: Keyword.get(opts, :backend_opts, []),
      tools: tools,
      tool_schemas: Tools.schemas(tools),
      messages: rehydrate_messages(session_id),
      max_iterations: Keyword.get(opts, :max_iterations, @default_max_iterations),
      max_history_bytes: Keyword.get(opts, :max_history_bytes, @default_max_history_bytes),
      idle_timeout: idle_timeout(opts),
      idle_timer: nil,
      tool_call_history: MapSet.new(),
      busy?: false,
      turn_pid: nil
    }

    {:ok, arm_idle_timer(state)}
  end

  @doc false
  @impl GenServer
  @spec handle_call({:submit_user_message, String.t(), pid()}, GenServer.from(), map()) ::
          {:reply, :accepted | {:error, terminal()}, map()} | {:noreply, map()}
  def handle_call({:submit_user_message, _text, _caller}, _from, %{busy?: true} = state) do
    terminal =
      emit_terminal(state.session_id, terminal(:busy, "Session is already processing a message"))

    {:reply, {:error, terminal}, state}
  end

  def handle_call({:submit_user_message, text, caller}, _from, state) do
    parent = self()

    busy_state =
      state
      |> cancel_idle_timer()
      |> Map.merge(%{busy?: true, tool_call_history: MapSet.new(), turn_pid: nil})

    turn_pid =
      spawn_link(fn ->
        {result, new_state} = run_turn(busy_state, text)
        persist(new_state)
        send(parent, {:turn_finished, caller, result, new_state})
      end)

    {:reply, :accepted, %{busy_state | turn_pid: turn_pid}}
  end

  @doc false
  @impl GenServer
  @spec handle_call(:snapshot, GenServer.from(), map()) :: {:reply, [map()], map()}
  def handle_call(:snapshot, _from, state) do
    {:reply, state.messages, state}
  end

  @doc false
  @impl GenServer
  @spec handle_info(term(), map()) :: {:noreply, map()}
  # `:harness_cancel` is forwarded to the linked turn worker when a turn is in
  # flight; idle sessions drop it. The catch-all absorbs any late Port message
  # left over after a mid-turn cancel teardown without log noise.
  def handle_info(:harness_cancel, %{turn_pid: turn_pid} = state) when is_pid(turn_pid) do
    send(turn_pid, :harness_cancel)
    {:noreply, state}
  end

  def handle_info(:harness_cancel, state), do: {:noreply, state}

  def handle_info({:turn_finished, caller, result, new_state}, _state) do
    send(caller, {:harness_chat_turn, caller, result})
    {:noreply, new_state |> Map.put(:busy?, false) |> Map.put(:turn_pid, nil) |> arm_idle_timer()}
  end

  def handle_info(:session_idle_timeout, %{busy?: true} = state), do: {:noreply, state}

  def handle_info(:session_idle_timeout, state), do: {:stop, :normal, state}

  def handle_info(_msg, state), do: {:noreply, state}

  @spec run_turn(map(), String.t()) :: {{:ok, map()} | {:error, terminal()}, map()}
  defp run_turn(state, text) do
    state = append_user_message(state, text)

    case ensure_history_limit(state) do
      {:ok, state} -> loop(state, 0)
      {:error, terminal, state} -> {{:error, terminal}, state}
    end
  end

  @spec loop(map(), non_neg_integer()) :: {{:ok, map()} | {:error, terminal()}, map()}
  defp loop(state, iteration) do
    if iteration >= state.max_iterations do
      {:error, terminal, state} =
        abort(state, :max_iterations, "Exceeded max iterations (#{state.max_iterations})")

      {{:error, terminal}, state}
    else
      case stream_once(state) do
        {:done, response, state} ->
          Stream.broadcast(state.session_id, %{type: "done", response: response})
          {{:ok, response}, state}

        {:tools, tool_uses, state} ->
          continue_after_tools(state, tool_uses, iteration)

        {:error, terminal, state} ->
          {{:error, terminal}, state}
      end
    end
  end

  @spec continue_after_tools(map(), [map()], non_neg_integer()) ::
          {{:ok, map()} | {:error, terminal()}, map()}
  defp continue_after_tools(state, tool_uses, iteration) do
    case dispatch_tools(state, tool_uses) do
      {:ok, state} -> loop(state, iteration + 1)
      {:error, terminal, state} -> {{:error, terminal}, state}
    end
  end

  @spec stream_once(map()) :: {:done, map(), map()} | {:tools, [map()], map()} | {:error, terminal(), map()}
  defp stream_once(state) do
    request = %{
      messages: state.messages,
      tools: state.tool_schemas,
      system: Keyword.get(state.backend_opts, :system, default_system_prompt())
    }

    callback = fn event -> stream_event(state.session_id, event) end

    # Inject `state.session_id` so backends that need a stable per-session
    # workspace (e.g. `Harness.Chat.Claude`'s per-session cwd) can derive one
    # deterministically. Backends that ignore the key (FunBackend in tests,
    # any future provider) are unaffected.
    backend_opts = Keyword.put(state.backend_opts, :session_id, state.session_id)

    case state.backend.stream(request, callback, backend_opts) do
      {:ok, response} ->
        content = normalize_content(response)
        assistant = %{role: :assistant, content: content}
        state = %{state | messages: state.messages ++ [assistant]}

        case extract_tool_uses(content) do
          [] -> {:done, response, state}
          tool_uses -> {:tools, tool_uses, state}
        end

      {:error, error} ->
        {reason, message} = backend_error_terminal(error)
        {:error, emit_terminal(state.session_id, terminal(reason, message, %{error: error})), state}
    end
  end

  @spec dispatch_tools(map(), [map()]) :: {:ok, map()} | {:error, terminal(), map()}
  defp dispatch_tools(state, tool_uses) do
    # Accumulate new tool-result messages in a separate `new_msgs` list (prepend,
    # O(1) per iteration), then apply a single Enum.reverse + ++ on the success
    # path. The prior form used `acc.messages ++ [msg]` inside the reduce, which
    # re-traversed the growing list every iteration — O(n²) over a long session.
    #
    # Error paths return `acc` without the pending new_msgs — a halt on tool N
    # doesn't commit the partial tool-result messages for tools 1..N-1. This is
    # acceptable: an aborted dispatch terminates the turn; the partial results have
    # no meaningful consumer.
    tool_uses
    |> Enum.reduce_while({:ok, state, []}, fn tool_use, {:ok, acc, new_msgs} ->
      id = Map.fetch!(tool_use, :id)
      name = Map.fetch!(tool_use, :name)
      input = Map.get(tool_use, :input, %{})

      with :ok <- check_loop(acc, name, input),
           {:ok, result} <- Tools.dispatch(acc.tools, name, input) do
        encoded = encode_tool_result(result)
        fingerprint = {name, normalize_input(input)}

        Stream.broadcast(acc.session_id, %{type: "tool_result", id: id, name: name, content: encoded})

        tool_result = %{type: "tool_result", tool_use_id: id, content: encoded}
        msg = %{role: :user, content: [tool_result]}

        updated = %{acc | tool_call_history: MapSet.put(acc.tool_call_history, fingerprint)}

        {:cont, {:ok, updated, [msg | new_msgs]}}
      else
        {:error, {:unknown_tool, tool_name}} ->
          {:halt, abort(acc, :unknown_tool, "Unknown tool #{tool_name}", %{tool: tool_name})}

        {:error, {:schema_validation_failed, errors}} ->
          {:halt,
           abort(acc, :schema_validation_failed, "Tool arguments failed schema validation", %{
             errors: errors
           })}

        {:error, {:dispatch_failed, message}} ->
          {:halt, abort(acc, :dispatch_failed, message)}

        {:error, terminal} ->
          {:halt, {:error, terminal, acc}}
      end
    end)
    |> case do
      {:ok, state, new_msgs} ->
        {:ok, %{state | messages: state.messages ++ Enum.reverse(new_msgs)}}

      {:error, terminal, state} ->
        {:error, terminal, state}
    end
  end

  @spec check_loop(map(), String.t(), map()) :: :ok | {:error, terminal()}
  defp check_loop(state, name, input) do
    fingerprint = {name, normalize_input(input)}

    if MapSet.member?(state.tool_call_history, fingerprint) do
      {:error, emit_terminal(state.session_id, terminal(:loop_detected, "Repeated identical tool call: #{name}"))}
    else
      :ok
    end
  end

  @spec abort(map(), terminal_reason(), String.t(), map()) :: {:error, terminal(), map()}
  defp abort(state, reason, message, details \\ %{}) do
    terminal = emit_terminal(state.session_id, terminal(reason, message, details))
    {:error, terminal, state}
  end

  # Broadcasts a terminal to the session stream and returns it unchanged, so a
  # call site can both surface it to stream-only subscribers and thread it into
  # the synchronous `{:error, terminal, state}` reply. Every terminal flows
  # through here exactly once — never broadcast a terminal inline elsewhere.
  @spec emit_terminal(String.t(), terminal()) :: terminal()
  defp emit_terminal(session_id, terminal) do
    Stream.broadcast(session_id, terminal)
    terminal
  end

  @spec append_user_message(map(), String.t()) :: map()
  defp append_user_message(state, text) do
    %{state | messages: state.messages ++ [%{role: :user, content: text}]}
  end

  @spec ensure_history_limit(map()) :: {:ok, map()} | {:error, terminal(), map()}
  defp ensure_history_limit(state) do
    if history_bytes(state.messages) > state.max_history_bytes do
      {:error,
       emit_terminal(
         state.session_id,
         terminal(:max_history_bytes, "Conversation history exceeds #{state.max_history_bytes} bytes")
       ), state}
    else
      {:ok, state}
    end
  end

  @spec stream_event(String.t(), Backend.event()) :: :ok
  defp stream_event(session_id, {:text_delta, text}) do
    Stream.broadcast(session_id, %{type: "text_delta", text: text})
  end

  defp stream_event(session_id, {:tool_use, tool_use}) do
    Stream.broadcast(session_id, %{
      type: "tool_call",
      id: tool_use[:id] || tool_use["id"],
      name: tool_use[:name] || tool_use["name"],
      arguments: tool_use[:input] || tool_use["input"] || %{}
    })
  end

  defp stream_event(_session_id, _event), do: :ok

  @spec extract_tool_uses([map()]) :: [map()]
  defp extract_tool_uses(content) do
    Enum.flat_map(content, fn
      %{type: "tool_use", id: id, name: name} = block ->
        [%{id: id, name: name, input: Map.get(block, :input, %{})}]

      %{"type" => "tool_use", "id" => id, "name" => name} = block ->
        [%{id: id, name: name, input: Map.get(block, "input", %{})}]

      _ ->
        []
    end)
  end

  @spec normalize_content(map()) :: [map()]
  defp normalize_content(%{content: content}) when is_list(content), do: content
  defp normalize_content(_), do: []

  @spec encode_tool_result(term()) :: String.t()
  defp encode_tool_result(result), do: Jason.encode!(JSONSafe.encode(result, JSONSafe.chat_opts()))

  @spec history_bytes([map()]) :: non_neg_integer()
  defp history_bytes(messages), do: messages |> Jason.encode!() |> byte_size()

  @spec normalize_input(map()) :: map()
  defp normalize_input(input) do
    input
    |> Jason.encode!()
    |> Jason.decode!()
  end

  @spec terminal(terminal_reason(), String.t(), map()) :: terminal()
  defp terminal(reason, message, details \\ %{}) do
    Map.merge(%{type: :terminal, reason: reason, message: message}, details)
  end

  # A backend that honors `:harness_cancel` returns `{:error, %{type: :cancelled}}`;
  # surface that as a distinct `:cancelled` terminal (not a generic backend error)
  # so the UI can show "Stopped" rather than an error. Everything else is a
  # backend error.
  @spec backend_error_terminal(map()) :: {terminal_reason(), String.t()}
  defp backend_error_terminal(%{type: :cancelled} = error),
    do: {:cancelled, Map.get(error, :message, "Turn cancelled by operator")}

  defp backend_error_terminal(error), do: {:backend_error, error.message}

  @spec default_system_prompt() :: String.t()
  defp default_system_prompt do
    "You are the harness chat orchestrator. Use the provided tools to drive harness operations."
  end

  @spec via(String.t()) :: {:via, Registry, {module(), String.t()}}
  defp via(session_id), do: {:via, Registry, {@registry, session_id}}

  @spec idle_timeout(keyword()) :: pos_integer()
  defp idle_timeout(opts) do
    Keyword.get_lazy(opts, :idle_timeout, fn ->
      :harness
      |> Application.get_env(:chat, [])
      |> Keyword.get(:idle_timeout, @default_idle_timeout)
    end)
  end

  @spec arm_idle_timer(map()) :: map()
  defp arm_idle_timer(state) do
    state = cancel_idle_timer(state)
    ref = Process.send_after(self(), :session_idle_timeout, state.idle_timeout)
    %{state | idle_timer: ref}
  end

  @spec cancel_idle_timer(map()) :: map()
  defp cancel_idle_timer(%{idle_timer: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    %{state | idle_timer: nil}
  end

  defp cancel_idle_timer(state), do: state

  # Loads any saved transcript for this session id so a reopened session (after
  # a BEAM restart, or a deep-link to a session whose GenServer died) resumes
  # with its prior turns. Empty for a genuinely new session id.
  @spec rehydrate_messages(String.t()) :: [map()]
  defp rehydrate_messages(session_id) do
    case Store.load(session_id) do
      {:ok, %SessionRecord{messages: messages}} -> messages
      {:error, :not_found} -> []
    end
  end

  # Persists the session's messages after each completed turn (Task 93).
  # Best-effort, mirroring `Harness.ResultStore`: a failed write degrades
  # restart-survival but never fails the turn. Empty histories aren't persisted
  # — a freshly-minted session with no turns stays out of the store (it still
  # shows on the index as a live session).
  @spec persist(map()) :: :ok
  defp persist(%{messages: []}), do: :ok

  defp persist(%{session_id: session_id, messages: messages}) do
    case Store.save(session_id, messages) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("harness chat: persist failed for #{session_id}: #{inspect(reason)}")
    end

    :ok
  end
end
