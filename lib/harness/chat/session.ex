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
  alias Harness.Chat.Stream
  alias Harness.Chat.Tools

  require Logger

  @registry Harness.Chat.Registry
  @default_max_iterations 16
  @default_max_history_bytes 256 * 1024

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
    GenServer.call(via(session_id), {:user_message, text}, timeout)
  end

  @doc """
  Requests cancellation of an in-flight turn.

  The session GenServer is parked inside the backend's stream loop for the
  duration of a turn (the whole `{:user_message, _}` call runs synchronously),
  so cancellation cannot be a `GenServer.cast` — the mailbox would not be read
  until the turn ended. Instead we `send/2` the bare `:harness_cancel` signal
  to the session pid: a backend whose `stream/3` parks in a `receive` (e.g.
  `Harness.Chat.Claude`'s Port drive loop) matches it, tears down its work, and
  returns `{:error, %{type: :cancelled}}`, which surfaces as a `:cancelled`
  terminal. When the session is idle the signal is a no-op (see `handle_info/2`).

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

    {:ok,
     %{
       session_id: session_id,
       backend: Keyword.fetch!(opts, :backend),
       backend_opts: Keyword.get(opts, :backend_opts, []),
       tools: tools,
       tool_schemas: Tools.schemas(tools),
       messages: rehydrate_messages(session_id),
       max_iterations: Keyword.get(opts, :max_iterations, @default_max_iterations),
       max_history_bytes: Keyword.get(opts, :max_history_bytes, @default_max_history_bytes),
       tool_call_history: MapSet.new(),
       busy?: false
     }}
  end

  @doc false
  @impl GenServer
  @spec handle_call({:user_message, String.t()}, GenServer.from(), map()) ::
          {:reply, {:ok, map()} | {:error, terminal()}, map()}
  def handle_call({:user_message, _text}, _from, %{busy?: true} = state) do
    terminal = terminal(:busy, "Session is already processing a message")
    {:reply, {:error, terminal}, state}
  end

  def handle_call({:user_message, text}, _from, state) do
    state = %{state | busy?: true, tool_call_history: MapSet.new()}
    {result, state} = run_turn(state, text)
    persist(state)
    {:reply, result, %{state | busy?: false}}
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
  # `:harness_cancel` only reaches here when the session is idle — during a turn
  # the backend's stream `receive` consumes it first (see `cancel/1`). Idle =
  # nothing to cancel, so drop it. The catch-all also absorbs any late Port
  # message left over after a mid-turn cancel teardown without log noise.
  def handle_info(:harness_cancel, state), do: {:noreply, state}
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
    tool_uses
    |> Enum.reduce_while({:ok, state}, fn tool_use, {:ok, acc} ->
      id = Map.fetch!(tool_use, :id)
      name = Map.fetch!(tool_use, :name)
      input = Map.get(tool_use, :input, %{})

      with :ok <- check_loop(acc, name, input),
           {:ok, result} <- Tools.dispatch(acc.tools, name, input) do
        encoded = encode_tool_result(result)
        fingerprint = {name, normalize_input(input)}

        Stream.broadcast(acc.session_id, %{type: "tool_result", id: id, name: name, content: encoded})

        tool_result = %{type: "tool_result", tool_use_id: id, content: encoded}

        updated = %{
          acc
          | tool_call_history: MapSet.put(acc.tool_call_history, fingerprint),
            messages: acc.messages ++ [%{role: :user, content: [tool_result]}]
        }

        {:cont, {:ok, updated}}
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
      {:ok, state} -> {:ok, state}
      {:error, terminal, state} -> {:error, terminal, state}
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
  defp encode_tool_result(result), do: Jason.encode!(to_jsonable(result))

  @spec to_jsonable(term()) :: term()
  defp to_jsonable(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp to_jsonable(%_{} = struct), do: struct |> Map.from_struct() |> to_jsonable()
  defp to_jsonable(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), to_jsonable(v)} end)
  defp to_jsonable(list) when is_list(list), do: Enum.map(list, &to_jsonable/1)
  defp to_jsonable(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp to_jsonable(other) when is_binary(other) or is_number(other) or is_boolean(other) or is_nil(other), do: other
  defp to_jsonable(other), do: inspect(other)

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

  # Loads any saved transcript for this session id so a reopened session (after
  # a BEAM restart, or a deep-link to a session whose GenServer died) resumes
  # with its prior turns. Empty for a genuinely new session id.
  @spec rehydrate_messages(String.t()) :: [map()]
  defp rehydrate_messages(session_id) do
    case Store.load(session_id) do
      {:ok, %{messages: messages}} -> messages
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
