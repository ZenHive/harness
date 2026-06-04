defmodule Harness.Chat.Store do
  @moduledoc """
  Pluggable persistence for chat sessions (Task 93 / Task 140).

  Backends: `Harness.Chat.Store.File` (default) and `Harness.Chat.Store.Postgres`.
  Select via `config :harness, :chat_store_backend, Harness.Chat.Store.Postgres`.

  Disable with `config :harness, :chat_store, false` — `save/3` is a no-op `:ok`,
  `load/2` returns `{:error, :not_found}`, `list/1` returns `[]`.
  """

  @typedoc "A loaded session record: the rehydration payload for `Harness.Chat.Session`."
  @type record :: %{session_id: String.t(), messages: [map()], updated_at: DateTime.t()}

  @typedoc "An index summary: the per-row payload `Harness.Dashboard.ChatLive` renders."
  @type summary :: %{
          session_id: String.t(),
          label: String.t(),
          message_count: non_neg_integer(),
          updated_at: DateTime.t()
        }

  @doc "Persists a session's messages with implementation-specific options."
  @callback save(String.t(), [map()], keyword()) :: :ok | {:error, term()}

  @doc "Loads a persisted session by id."
  @callback load(String.t(), keyword()) :: {:ok, record()} | {:error, :not_found}

  @doc "Lists persisted sessions as index summaries."
  @callback list(keyword()) :: [summary()]

  @doc """
  Persists a session's messages. Best-effort — failures degrade restart-survival only.
  """
  @spec save(String.t(), [map()], keyword()) :: :ok | {:error, term()}
  def save(session_id, messages, opts \\ []) when is_binary(session_id) and is_list(messages) do
    dispatch(opts, :save, [session_id, messages, opts])
  end

  @doc "Loads a persisted session by id."
  @spec load(String.t(), keyword()) :: {:ok, record()} | {:error, :not_found}
  def load(session_id, opts \\ []) when is_binary(session_id) do
    dispatch(opts, :load, [session_id, opts])
  end

  @doc "Lists every persisted session as an index summary, most-recently-updated first."
  @spec list(keyword()) :: [summary()]
  def list(opts \\ []) do
    dispatch(opts, :list, [opts])
  end

  @doc false
  @spec derive_label([map()]) :: String.t()
  def derive_label(messages) do
    Enum.find_value(messages, "New chat", fn
      %{role: :user, content: text} when is_binary(text) -> truncate_label(text)
      %{"role" => "user", "content" => text} when is_binary(text) -> truncate_label(text)
      _ -> nil
    end)
  end

  @doc "Returns the configured chat store backend module (default `Harness.Chat.Store.File`)."
  @spec configured() :: module()
  def configured do
    Application.get_env(:harness, :chat_store_backend, Harness.Chat.Store.File)
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

  @spec dispatch(keyword(), atom(), [term()]) :: term()
  defp dispatch(opts, function, args) do
    backend = Keyword.get(opts, :backend, configured())
    apply(backend, function, args)
  end
end
