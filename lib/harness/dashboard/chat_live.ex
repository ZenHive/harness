defmodule Harness.Dashboard.ChatLive do
  @moduledoc """
  LiveView UI for the chat orchestrator (Task 78).

  Mounts at `/harness/chat` (creates a fresh session, then `push_patch` to the
  deep-link URL) and `/harness/chat/:session_id` (reconnects to an existing
  `Harness.Chat.Session` GenServer). Subscribes to
  `Harness.Chat.Stream.topic(session_id)` and renders streaming tokens,
  collapsible tool-call blocks, and a composer form.

  ## Streams-only message list

  Every message — user, assistant (including the actively-streaming turn),
  tool-result, and terminal — lives in `@streams.messages` with a stable
  per-turn DOM id. Token chunks arrive via PubSub and replace the active
  assistant message in place via `stream_insert(..., at: -1)` — the DOM id
  stays constant across all chunks so `phx-update="stream"` updates without
  re-rendering the list.

  A small server-side `:active` mirror accumulates chunks before each
  `stream_insert` so we can rewrite the most-recent message with the
  newly-accumulated text. Once the session broadcasts `:done` or `:terminal`,
  `:active` clears and the next user submission seeds a fresh turn.

  ## Bounded buffers

  Two server-side caps protect against runaway streams (CSS overflow is
  decoration, not enforcement):

    * `@max_message_bytes` — 64 KiB of accumulated text per assistant turn;
      excess deltas are dropped at the LiveView boundary with a single
      truncation sentinel appended.
    * `@max_messages_per_session` — 200 messages per session; when exceeded
      on a completed turn, the oldest is `stream_delete`d.

  ## No `raw/1` on LLM-supplied content

  Tool-call args and results are parsed maps / lists rendered by the
  recursive `json_tree` function component. The component pattern-matches
  on value type and emits structured DOM (`<dl>`, `<ol>`, typed leaf spans);
  it never `Jason.encode!` + `Phoenix.HTML.raw/1`s a string into a `<pre>`.

  ## Acceptance-criteria pointers

    * `stream/3` + `phx-update="stream"` — `mount/3` and the `messages` div.
    * `<.message_row>`, `<.tool_call>`, `<.json_tree>` — `Phoenix.Component`s
      with `attr/3` declarations below.
    * HEEx `:if` / `:for` special attrs — no `<%= if/for %>` wrappers.
    * `prefers-reduced-motion` — gated at the CSS layer in
      `Harness.Dashboard.Tokens`; never branched server-side.
    * Snapshot replay — `handle_params/3` with `:show` action calls
      `Harness.Chat.Session.snapshot/1` and `stream(..., reset: true)`.
  """

  use Phoenix.LiveView, layout: {Harness.Dashboard.Layouts, :app}

  alias Harness.Chat.Session
  alias Harness.Chat.Store
  alias Harness.Chat.Stream
  alias Harness.Chat.Supervisor, as: ChatSupervisor
  alias Harness.Dashboard.Components
  alias Phoenix.LiveView.JS
  alias Phoenix.LiveView.Rendered
  alias Phoenix.LiveView.Socket

  @max_message_bytes 64 * 1024
  @max_messages_per_session 200

  @doc false
  @spec max_message_bytes() :: non_neg_integer()
  def max_message_bytes, do: @max_message_bytes

  @doc false
  @spec max_messages_per_session() :: non_neg_integer()
  def max_messages_per_session, do: @max_messages_per_session

  @impl Phoenix.LiveView
  @spec mount(map(), map(), Socket.t()) :: {:ok, Socket.t()}
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream_configure(:messages, dom_id: &"msg-#{&1.id}")
     |> stream(:messages, [])
     |> assign(:session_id, nil)
     |> assign(:active, nil)
     |> assign(:input, "")
     |> assign(:message_ids, [])
     |> assign(:empty?, true)
     |> assign(:sessions, [])
     |> assign(:playbooks, Harness.Playbooks.list())}
  end

  @impl Phoenix.LiveView
  @spec handle_params(map(), String.t(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @spec apply_action(Socket.t(), atom(), map()) :: Socket.t()
  defp apply_action(socket, :index, _params) do
    socket
    |> maybe_unsubscribe(socket.assigns.session_id)
    |> assign(:session_id, nil)
    |> assign(:active, nil)
    |> assign(:sessions, list_index_sessions())
  end

  defp apply_action(socket, :show, %{"session_id" => id}) do
    socket
    |> maybe_unsubscribe(socket.assigns.session_id)
    |> ensure_session(id)
    |> subscribe(id)
    |> assign(:session_id, id)
    |> assign(:active, nil)
    |> load_snapshot(id)
  end

  @spec maybe_unsubscribe(Socket.t(), String.t() | nil) :: Socket.t()
  defp maybe_unsubscribe(socket, nil), do: socket

  defp maybe_unsubscribe(socket, id) when is_binary(id) do
    if connected?(socket), do: Stream.unsubscribe(id)
    socket
  end

  @spec subscribe(Socket.t(), String.t()) :: Socket.t()
  defp subscribe(socket, id) do
    if connected?(socket), do: Stream.subscribe(id)
    socket
  end

  @spec ensure_session(Socket.t(), String.t()) :: Socket.t()
  defp ensure_session(socket, id) do
    case ChatSupervisor.whereis(id) do
      nil ->
        case ChatSupervisor.start_session(session_start_opts(id)) do
          {:ok, ^id, _pid} -> socket
          {:error, _reason} -> socket
        end

      _pid ->
        socket
    end
  end

  # The keyword list ChatLive hands to ChatSupervisor.start_session/1. Extracted
  # so a unit test can pin both the backend choice AND that this call shape is
  # accepted — Session.init/1 requires :backend via Keyword.fetch!/2, and an
  # earlier revision omitted it, causing every chat session to fail silently
  # (the LiveView swallows {:error, _reason} below).
  @doc false
  @spec session_start_opts(String.t()) :: keyword()
  def session_start_opts(id), do: [id: id, backend: Harness.Chat.Claude]

  @spec load_snapshot(Socket.t(), String.t()) :: Socket.t()
  defp load_snapshot(socket, id) do
    case Session.snapshot(id) do
      {:ok, raw_messages} ->
        messages = normalize_snapshot(raw_messages)

        socket
        |> stream(:messages, messages, reset: true)
        |> assign(:message_ids, Enum.map(messages, & &1.id))
        |> assign(:empty?, messages == [])

      {:error, :not_found} ->
        socket
        |> stream(:messages, [], reset: true)
        |> assign(:message_ids, [])
        |> assign(:empty?, true)
    end
  end

  ## --- PubSub events --------------------------------------------------------

  @impl Phoenix.LiveView
  @spec handle_info(term(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_info({:harness_chat_stream, sid, _event}, socket) when sid != socket.assigns.session_id do
    {:noreply, socket}
  end

  def handle_info({:harness_chat_stream, _sid, event}, socket) do
    {:noreply, apply_event(socket, event)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @spec apply_event(Socket.t(), map()) :: Socket.t()
  defp apply_event(socket, %{type: "text_delta", text: text}) do
    socket
    |> ensure_active()
    |> update_active(fn active -> %{active | text: append_bounded(active.text, text)} end)
    |> push_active()
  end

  defp apply_event(socket, %{type: "tool_call", id: id, name: name, arguments: args}) do
    tool = %{id: to_string(id), name: to_string(name), args: args, result: nil, status: :pending}

    socket
    |> ensure_active()
    |> update_active(fn active -> %{active | tool_calls: active.tool_calls ++ [tool]} end)
    |> push_active()
  end

  defp apply_event(socket, %{type: "tool_result", id: id} = event) do
    decoded = decode_tool_result(Map.get(event, :content) || Map.get(event, "content"))
    target_id = to_string(id)

    socket
    |> ensure_active()
    |> update_active(fn active ->
      %{active | tool_calls: set_tool_result(active.tool_calls, target_id, decoded)}
    end)
    |> push_active()
  end

  defp apply_event(socket, %{type: "done"}) do
    case socket.assigns.active do
      nil ->
        socket

      active ->
        socket
        |> assign(:active, %{active | streaming?: false})
        |> push_active()
        |> assign(:active, nil)
        |> prune_overflow()
    end
  end

  defp apply_event(socket, %{type: :terminal, reason: reason} = event) do
    message = Map.get(event, :message) || Atom.to_string(reason)
    msg_id = "term-#{System.unique_integer([:positive])}"

    item = %{
      id: msg_id,
      role: :terminal,
      text: message,
      streaming?: false,
      tool_calls: [],
      reason: reason
    }

    socket
    |> flush_active_if_any()
    |> stream_insert(:messages, item, at: -1)
    |> assign(:message_ids, socket.assigns.message_ids ++ [msg_id])
    |> assign(:empty?, false)
    |> assign(:active, nil)
    |> prune_overflow()
  end

  defp apply_event(socket, _event), do: socket

  @spec flush_active_if_any(Socket.t()) :: Socket.t()
  defp flush_active_if_any(%{assigns: %{active: nil}} = socket), do: socket

  defp flush_active_if_any(socket) do
    active = socket.assigns.active

    socket
    |> assign(:active, %{active | streaming?: false})
    |> push_active()
  end

  @spec ensure_active(Socket.t()) :: Socket.t()
  defp ensure_active(socket) do
    case socket.assigns.active do
      nil ->
        id = "asst-#{System.unique_integer([:positive])}"
        active = %{id: id, role: :assistant, text: "", tool_calls: [], streaming?: true}

        socket
        |> assign(:active, active)
        |> assign(:message_ids, socket.assigns.message_ids ++ [id])
        |> assign(:empty?, false)

      _active ->
        socket
    end
  end

  @spec update_active(Socket.t(), (map() -> map())) :: Socket.t()
  defp update_active(%{assigns: %{active: nil}} = socket, _fun), do: socket
  defp update_active(socket, fun), do: assign(socket, :active, fun.(socket.assigns.active))

  @spec push_active(Socket.t()) :: Socket.t()
  defp push_active(%{assigns: %{active: nil}} = socket), do: socket

  defp push_active(socket) do
    stream_insert(socket, :messages, socket.assigns.active, at: -1)
  end

  ## --- Composer events ------------------------------------------------------

  @impl Phoenix.LiveView
  @spec handle_event(String.t(), map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_event("input_change", %{"text" => text}, socket) do
    {:noreply, assign(socket, :input, text)}
  end

  def handle_event("send", %{"text" => text}, socket) do
    case prepare_send(socket, text) do
      :ignore ->
        {:noreply, socket}

      {:ok, trimmed, session_id} ->
        msg_id = "user-#{System.unique_integer([:positive])}"
        item = %{id: msg_id, role: :user, text: trimmed, streaming?: false, tool_calls: []}

        Task.Supervisor.start_child(Harness.Chat.TaskSupervisor, fn ->
          Session.user_message(session_id, trimmed, 600_000)
        end)

        socket =
          socket
          |> stream_insert(:messages, item, at: -1)
          |> assign(:message_ids, socket.assigns.message_ids ++ [msg_id])
          |> assign(:input, "")
          |> assign(:empty?, false)

        {:noreply, socket}
    end
  end

  def handle_event("new_chat", _params, socket) do
    new_id = generate_session_id()
    {:noreply, push_navigate(socket, to: "/harness/chat/#{new_id}")}
  end

  # Stop button. Signals the backend to tear down the in-flight turn; the
  # streaming indicator clears when the resulting `:cancelled` terminal arrives
  # over PubSub (handled by apply_event/2), so there's no local state to mutate.
  def handle_event("cancel", _params, socket) do
    if sid = socket.assigns.session_id, do: Session.cancel(sid)
    {:noreply, socket}
  end

  # Playbook chip → prefill the composer with the recipe request, leaving the
  # cursor after "for " for the operator to name the target project. The slug
  # (not the title) is interpolated so the orchestrator calls playbooks-get
  # with the name the catalog actually keys on.
  def handle_event("prefill", %{"name" => name}, socket) do
    {:noreply, assign(socket, :input, prefill_text(name))}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @spec prepare_send(Socket.t(), String.t()) :: :ignore | {:ok, String.t(), String.t()}
  defp prepare_send(socket, text) when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" -> :ignore
      socket.assigns.active != nil -> :ignore
      socket.assigns.session_id == nil -> :ignore
      true -> {:ok, trimmed, socket.assigns.session_id}
    end
  end

  ## --- Snapshot normalization ----------------------------------------------

  # Walks the Session's raw `:messages` field (Anthropic-shaped) and produces
  # the visual representation the stream renders: user messages stand alone;
  # each assistant message becomes one message_map with accumulated text and a
  # list of tool_calls; tool_result entries merge back into the preceding
  # assistant's tool_calls by id.
  @doc false
  @spec normalize_snapshot([map()]) :: [map()]
  def normalize_snapshot(messages) do
    # Entries accumulate newest-first (prepend), so merge_tool_results finds the
    # most recent assistant entry at the head; reversed once at the end.
    {acc, _idx} =
      Enum.reduce(messages, {[], 0}, fn msg, {acc, idx} ->
        case msg do
          %{role: :user, content: text} when is_binary(text) ->
            entry = %{
              id: "snap-user-#{idx}",
              role: :user,
              text: text,
              streaming?: false,
              tool_calls: []
            }

            {[entry | acc], idx + 1}

          %{role: :user, content: blocks} when is_list(blocks) ->
            {acc2, idx2} = merge_tool_results(acc, blocks, idx)
            {acc2, idx2}

          %{role: :assistant, content: blocks} when is_list(blocks) ->
            entry = assistant_entry(blocks, idx)
            {[entry | acc], idx + 1}

          _ ->
            {acc, idx}
        end
      end)

    Enum.reverse(acc)
  end

  @spec assistant_entry([map()], non_neg_integer()) :: map()
  defp assistant_entry(blocks, idx) do
    text =
      blocks
      |> Enum.filter(&block_text?/1)
      |> Enum.map_join(&block_text/1)
      |> truncate_bounded()

    tool_calls =
      blocks
      |> Enum.filter(&block_tool_use?/1)
      |> Enum.map(fn b ->
        %{
          id: block_field(b, :id, "id"),
          name: block_field(b, :name, "name"),
          args: block_field(b, :input, "input") || %{},
          result: nil,
          status: :pending
        }
      end)

    %{
      id: "snap-asst-#{idx}",
      role: :assistant,
      text: text,
      streaming?: false,
      tool_calls: tool_calls
    }
  end

  @spec merge_tool_results([map()], [map()], non_neg_integer()) :: {[map()], non_neg_integer()}
  defp merge_tool_results(acc, blocks, idx) do
    Enum.reduce(blocks, {acc, idx}, fn block, {acc2, idx2} ->
      case block do
        %{type: "tool_result"} ->
          tool_use_id = block_field(block, :tool_use_id, "tool_use_id")
          content = block_field(block, :content, "content")
          decoded = decode_tool_result(content)
          {merge_one_result(acc2, tool_use_id, decoded), idx2}

        _ ->
          {acc2, idx2}
      end
    end)
  end

  # `acc` is newest-first (see normalize_snapshot), so the first assistant entry
  # found IS the most recent one — no reverse needed.
  @spec merge_one_result([map()], String.t() | nil, term()) :: [map()]
  defp merge_one_result(acc, nil, _decoded), do: acc

  defp merge_one_result(acc, tool_use_id, decoded) do
    mark_last_with_tool(acc, to_string(tool_use_id), decoded)
  end

  @spec mark_last_with_tool([map()], String.t(), term()) :: [map()]
  defp mark_last_with_tool([%{role: :assistant} = entry | rest], target, decoded) do
    [%{entry | tool_calls: set_tool_result(entry.tool_calls, target, decoded)} | rest]
  end

  defp mark_last_with_tool([head | rest], target, decoded) do
    [head | mark_last_with_tool(rest, target, decoded)]
  end

  defp mark_last_with_tool([], _target, _decoded), do: []

  @spec block_text?(map()) :: boolean()
  defp block_text?(%{type: "text"}), do: true
  defp block_text?(%{"type" => "text"}), do: true
  defp block_text?(_), do: false

  @spec block_text(map()) :: String.t()
  defp block_text(%{type: "text", text: text}) when is_binary(text), do: text
  defp block_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp block_text(_), do: ""

  @spec block_tool_use?(map()) :: boolean()
  defp block_tool_use?(%{type: "tool_use"}), do: true
  defp block_tool_use?(%{"type" => "tool_use"}), do: true
  defp block_tool_use?(_), do: false

  @spec block_field(map(), atom(), String.t()) :: term()
  defp block_field(map, atom_key, string_key) do
    case Map.fetch(map, atom_key) do
      {:ok, v} -> v
      :error -> Map.get(map, string_key)
    end
  end

  ## --- Buffer bounding ------------------------------------------------------

  @doc false
  @spec append_bounded(String.t(), String.t()) :: String.t()
  def append_bounded(existing, addition) do
    cond do
      String.ends_with?(existing, "\n[…truncated]") ->
        existing

      byte_size(existing) + byte_size(addition) <= @max_message_bytes ->
        existing <> addition

      true ->
        room = max(@max_message_bytes - byte_size(existing), 0)
        existing <> safe_byte_prefix(addition, room) <> "\n[…truncated]"
    end
  end

  @spec truncate_bounded(String.t()) :: String.t()
  defp truncate_bounded(text) when byte_size(text) <= @max_message_bytes, do: text

  defp truncate_bounded(text) do
    safe_byte_prefix(text, @max_message_bytes) <> "\n[…truncated]"
  end

  # Takes the leading `max_bytes` of `bin`, then trims any trailing bytes that
  # would leave a split multi-byte UTF-8 codepoint. A streamed `text_delta` can
  # land mid-codepoint, and a raw `binary_part/3` byte slice would yield an
  # invalid binary that LiveView refuses to render. A codepoint is ≤4 bytes, so
  # the trim drops at most 3 bytes.
  @spec safe_byte_prefix(binary(), non_neg_integer()) :: binary()
  defp safe_byte_prefix(bin, max_bytes) do
    bin
    |> binary_part(0, min(max_bytes, byte_size(bin)))
    |> trim_to_valid_utf8()
  end

  @spec trim_to_valid_utf8(binary()) :: binary()
  defp trim_to_valid_utf8(bin) do
    cond do
      String.valid?(bin) -> bin
      byte_size(bin) == 0 -> bin
      true -> trim_to_valid_utf8(binary_part(bin, 0, byte_size(bin) - 1))
    end
  end

  @doc false
  @spec set_tool_result([map()], String.t(), term()) :: [map()]
  def set_tool_result(tools, target_id, decoded) do
    Enum.map(tools, fn tc ->
      if to_string(tc.id) == target_id do
        %{tc | result: decoded, status: :done}
      else
        tc
      end
    end)
  end

  @spec decode_tool_result(term()) :: term()
  defp decode_tool_result(nil), do: nil

  defp decode_tool_result(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, value} -> value
      {:error, _} -> content
    end
  end

  defp decode_tool_result(other), do: other

  @spec prune_overflow(Socket.t()) :: Socket.t()
  defp prune_overflow(socket) do
    ids = socket.assigns.message_ids

    if length(ids) <= @max_messages_per_session do
      socket
    else
      drop = length(ids) - @max_messages_per_session
      {to_remove, kept} = Enum.split(ids, drop)

      socket =
        Enum.reduce(to_remove, socket, fn id, sock ->
          stream_delete(sock, :messages, %{id: id})
        end)

      assign(socket, :message_ids, kept)
    end
  end

  @spec generate_session_id() :: String.t()
  defp generate_session_id do
    "chat-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  @doc false
  # The composer prefill for a playbook chip. Slug (not title) so the
  # orchestrator's playbooks-get call keys on the catalog name; trailing
  # "for " leaves the cursor where the operator names the target project.
  @spec prefill_text(String.t()) :: String.t()
  def prefill_text(name) when is_binary(name), do: "run the #{name} playbook for "

  ## --- Index session list ---------------------------------------------------

  # Merges live sessions (from the Registry) with persisted-but-dead ones (from
  # the file store), keyed by session id so a session that is both live and
  # persisted appears once — the live snapshot wins (it's the fresher truth).
  # Live sessions sort to the top; persisted ones follow by most-recent-first.
  @spec list_index_sessions() :: [map()]
  defp list_index_sessions do
    live =
      ChatSupervisor.list_sessions()
      |> Enum.flat_map(&live_summary/1)
      |> Map.new(&{&1.session_id, &1})

    persisted = Map.new(Store.list(), &{&1.session_id, Map.put(&1, :live?, false)})

    persisted
    |> Map.merge(live)
    |> Map.values()
    |> Enum.sort_by(&{if(&1.live?, do: 1, else: 0), updated_sort_key(&1.updated_at)}, :desc)
  end

  # A live session's summary, derived from its in-memory snapshot. Returns `[]`
  # when the session died between the Registry list and this snapshot call (a
  # benign race) so the merge simply drops it.
  @spec live_summary(String.t()) :: [map()]
  defp live_summary(id) do
    case Session.snapshot(id) do
      {:ok, messages} ->
        [
          %{
            session_id: id,
            label: Store.derive_label(messages),
            message_count: length(messages),
            updated_at: nil,
            live?: true
          }
        ]

      {:error, :not_found} ->
        []
    end
  end

  @spec updated_sort_key(DateTime.t() | nil) :: integer()
  defp updated_sort_key(nil), do: 0
  defp updated_sort_key(%DateTime{} = dt), do: DateTime.to_unix(dt)

  ## --- Render ---------------------------------------------------------------

  @impl Phoenix.LiveView
  @spec render(map()) :: Rendered.t()
  def render(%{live_action: :index} = assigns), do: render_index(assigns)

  def render(assigns) do
    ~H"""
    <.chat_shell session_id={@session_id} disabled?={@active != nil}>
      <:empty>
        <div :if={@empty?} class="empty-state">
          New chat session. Type a message below — the agent will use harness tools
          to drive the request and stream its reply here.
        </div>
      </:empty>

      <div id="messages" phx-update="stream" class="messages">
        <Components.message_row
          :for={{dom_id, msg} <- @streams.messages}
          dom_id={dom_id}
          role={msg.role}
          text={msg.text}
          streaming?={Map.get(msg, :streaming?, false)}
          tool_calls={Map.get(msg, :tool_calls, [])}
        />
      </div>

      <.playbook_bar playbooks={@playbooks} />

      <form phx-submit="send" phx-change="input_change" class="composer">
        <textarea
          name="text"
          aria-label="Message"
          placeholder="Send a message…"
          rows="2"
          autocomplete="off"
          autofocus
          phx-debounce="150"
        ><%= @input %></textarea>
        <button :if={@active == nil} type="submit" disabled={@session_id == nil}>Send</button>
        <button :if={@active != nil} type="button" class="stop-btn" phx-click="cancel">Stop</button>
      </form>
    </.chat_shell>
    """
  end

  @spec render_index(map()) :: Rendered.t()
  defp render_index(assigns) do
    ~H"""
    <div class="chat-index">
      <header class="chat-header">
        <h1>Chats</h1>
        <button type="button" phx-click="new_chat">New chat</button>
      </header>

      <p :if={@sessions == []} class="empty-state">
        No chat sessions yet. Start one with “New chat”.
      </p>

      <ul :if={@sessions != []} class="session-list">
        <li :for={session <- @sessions} class="session-card">
          <a class="session-link" href={"/harness/chat/#{session.session_id}"}>
            <span class="session-label">{session.label}</span>
            <span class="session-meta">
              <span :if={session.live?} class="session-live">live</span>
              <span class="session-id">{session.session_id}</span>
              <span class="session-count">{session.message_count} msgs</span>
              <span :if={session.updated_at} class="session-time">
                {Calendar.strftime(session.updated_at, "%Y-%m-%d %H:%M UTC")}
              </span>
            </span>
          </a>
        </li>
      </ul>
    </div>
    """
  end

  ## --- Function components --------------------------------------------------

  attr(:playbooks, :list, required: true, doc: "Catalog summary maps from Harness.Playbooks.list/0")

  @doc "Chip row that prefills the composer with a playbook request on click."
  @spec playbook_bar(map()) :: Rendered.t()
  def playbook_bar(assigns) do
    ~H"""
    <div :if={@playbooks != []} class="playbook-bar">
      <span class="label">Playbooks</span>
      <button
        :for={pb <- @playbooks}
        type="button"
        class="playbook-chip"
        phx-click={JS.push("prefill") |> JS.focus(to: "textarea[name=text]")}
        phx-value-name={pb.name}
        title={pb.summary}
      >
        {pb.title}
      </button>
    </div>
    """
  end

  attr(:session_id, :string, default: nil)
  attr(:disabled?, :boolean, default: false)
  slot(:empty)
  slot(:inner_block, required: true)

  @spec chat_shell(map()) :: Rendered.t()
  def chat_shell(assigns) do
    ~H"""
    <div class="chat-shell">
      <header class="chat-header">
        <div>
          <h1>Chat</h1>
          <span :if={@session_id} class="session-id">{@session_id}</span>
        </div>
        <div>
          <button type="button" phx-click="new_chat">New chat</button>
        </div>
      </header>

      {render_slot(@empty)}
      {render_slot(@inner_block)}
    </div>
    """
  end
end
