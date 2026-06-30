defmodule Harness.Chat.Store do
  @moduledoc """
  Pluggable persistence boundary for chat sessions (Task 93, Task 140).

  The core talks only to this behaviour. Defaults follow `:repo_enabled`:
  `Harness.Chat.Store.Postgres` for durable deployments and
  `Harness.Chat.Store.Memory` for ephemeral repo-disabled nodes. Explicit
  `:chat_store_backend` config still wins.

  ## Selecting a backend

  Configure another module (optionally with backend opts) via
  `:chat_store_backend`:

      config :harness, :chat_store_backend, Harness.Chat.Store.Postgres
      config :harness, :chat_store_backend, {Harness.Chat.Store.Postgres, repo: MyRepo}

  ## What is persisted

  A session's raw `Harness.Chat.Session` `:messages` (Anthropic-shaped) plus an
  `updated_at` stamp. `Harness.Chat.Session` calls `save/3` after each completed
  turn and rehydrates via `load/2` on init, so a transcript survives a BEAM
  restart: reopening `/harness/chat/<session_id>` replays the saved turns.

  ## Bounding

  Each backend keeps only the most recent 200 messages (mirroring
  `Harness.Dashboard.ChatLive`'s live cap) so the store does not grow unbounded.
  Per-turn text is already byte-bounded upstream by the session's
  `:max_history_bytes` guard.

  ## Ephemeral mode

  When `:repo_enabled` is false, chat sessions are in-memory only. They remain
  available while the node runs and disappear on restart.
  """

  alias Harness.Chat.Store.SessionRecord

  @typedoc "A loaded session record: the rehydration payload for `Harness.Chat.Session`."
  @type session_record :: SessionRecord.t()

  @typedoc "An index summary: the per-row payload `Harness.Dashboard.ChatLive` renders."
  @type summary :: %{
          session_id: String.t(),
          label: String.t(),
          message_count: non_neg_integer(),
          updated_at: DateTime.t()
        }

  @typedoc "A configured chat store backend module, with optional module-specific options."
  @type backend :: module() | {module(), keyword()}

  @doc "Persists a session's messages (bounded to the most recent 200) with a fresh `updated_at`."
  @callback save(String.t(), [map()], keyword()) :: :ok | {:error, term()}

  @doc "Loads a persisted session by id, or `{:error, :not_found}`."
  @callback load(String.t(), keyword()) :: {:ok, session_record()} | {:error, :not_found}

  @doc "Lists every persisted session as an index `summary`, most-recently-updated first."
  @callback list(keyword()) :: [summary()]

  @doc """
  Persists a session's messages via the configured backend.

  Best-effort: returns `:ok` when the store is disabled or the write succeeds,
  `{:error, reason}` on failure (the caller logs and continues — a failed persist
  degrades restart-survival, it does not fail the turn).
  """
  @spec save(String.t(), [map()], keyword()) :: :ok | {:error, term()}
  def save(session_id, messages, opts \\ []) when is_binary(session_id) and is_list(messages) do
    dispatch(:save, [session_id, messages], opts)
  end

  @doc "Loads a persisted session by id via the configured backend."
  @spec load(String.t(), keyword()) :: {:ok, session_record()} | {:error, :not_found}
  def load(session_id, opts \\ []) when is_binary(session_id) do
    dispatch(:load, [session_id], opts)
  end

  @doc "Lists persisted sessions via the configured backend, most-recently-updated first."
  @spec list(keyword()) :: [summary()]
  def list(opts \\ []) do
    dispatch(:list, [], opts)
  end

  # Derives a recognizable label from a session's messages — the first user
  # message text, truncated, or "New chat" when none exists yet. Exposed (not
  # `defp`) so the backends and `Harness.Dashboard.ChatLive` label sessions with
  # the same rule; `@doc false` keeps it off the public surface.
  @doc false
  @spec derive_label([map()]) :: String.t()
  def derive_label(messages) do
    Enum.find_value(messages, "New chat", fn
      %{role: :user, content: text} when is_binary(text) -> truncate_label(text)
      %{"role" => "user", "content" => text} when is_binary(text) -> truncate_label(text)
      _ -> nil
    end)
  end

  @doc false
  @spec configured() :: backend()
  def configured do
    case Application.get_env(:harness, :chat_store_backend) do
      nil ->
        if Application.get_env(:harness, :repo_enabled, true) do
          Harness.Chat.Store.Postgres
        else
          Harness.Chat.Store.Memory
        end

      backend ->
        backend
    end
  end

  @spec truncate_label(String.t()) :: String.t()
  defp truncate_label(text) do
    trimmed = text |> String.trim() |> String.replace(~r/\s+/, " ")

    cond do
      trimmed == "" -> "New chat"
      String.length(trimmed) <= 60 -> trimmed
      true -> String.slice(trimmed, 0, 60) <> "…"
    end
  end

  @spec dispatch(atom(), [term()], keyword()) :: term()
  defp dispatch(function, args, call_opts) do
    case configured() do
      {module, opts} when is_atom(module) and is_list(opts) ->
        apply(module, function, args ++ [Keyword.merge(opts, call_opts)])

      module when is_atom(module) ->
        apply(module, function, args ++ [call_opts])
    end
  end
end
