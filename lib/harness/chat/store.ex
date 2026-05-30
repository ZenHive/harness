defmodule Harness.Chat.Store do
  @moduledoc """
  File-backed persistence for chat sessions (Task 93).

  Mirrors `Harness.ResultStore.File`: one Erlang external-term file per session
  under a configured root, written via a `.tmp` sibling + atomic rename so a
  concurrent reader never sees a torn file. Kept deliberately single-module —
  unlike `Harness.ResultStore`, chat persistence has no pluggable-backend
  requirement (Postgres via `Harness.Repo` is available but file-backed is the
  lighter match for ephemeral-ish transcripts), so there is no behaviour split.

  ## What is persisted

  A session's raw `Harness.Chat.Session` `:messages` (Anthropic-shaped) plus an
  `updated_at` stamp. `Harness.Chat.Session` calls `save/3` after each completed
  turn and rehydrates via `load/2` on init, so a transcript survives a BEAM
  restart: reopening `/harness/chat/<session_id>` replays the saved turns.

  ## Bounding

  `save/3` keeps only the most recent `@max_persisted_messages` messages
  (mirroring `Harness.Dashboard.ChatLive`'s live 200-message cap) so the store
  does not grow unbounded. Per-turn text is already byte-bounded upstream by the
  session's `:max_history_bytes` guard.

  ## Disabling

  `config :harness, :chat_store, false` (or `nil`) short-circuits every function:
  `save/3` is a no-op `:ok`, `load/2` returns `{:error, :not_found}`, `list/1`
  returns `[]`. Otherwise configure the root with
  `config :harness, :chat_store, root: "/some/path"`.
  """

  require Logger

  @default_root "~/.harness/chats"
  @max_persisted_messages 200

  @typedoc "A loaded session record: the rehydration payload for `Harness.Chat.Session`."
  @type record :: %{session_id: String.t(), messages: [map()], updated_at: DateTime.t()}

  @typedoc "An index summary: the per-row payload `Harness.Dashboard.ChatLive` renders."
  @type summary :: %{
          session_id: String.t(),
          label: String.t(),
          message_count: non_neg_integer(),
          updated_at: DateTime.t()
        }

  @doc """
  Persists a session's messages (bounded to the most recent
  `#{@max_persisted_messages}`) with a fresh `updated_at`.

  Best-effort: returns `:ok` when the store is disabled or the write succeeds,
  `{:error, reason}` on a write failure (the caller logs and continues — a
  failed persist degrades restart-survival, it does not fail the turn).
  """
  @spec save(String.t(), [map()], keyword()) :: :ok | {:error, term()}
  def save(session_id, messages, opts \\ []) when is_binary(session_id) and is_list(messages) do
    case root(opts) do
      nil ->
        :ok

      dir ->
        record = %{
          session_id: session_id,
          messages: Enum.take(messages, -@max_persisted_messages),
          updated_at: DateTime.utc_now()
        }

        write_term(session_path(dir, session_id), record)
    end
  end

  @doc """
  Loads a persisted session by id.

  Returns `{:ok, record}` or `{:error, :not_found}` when the store is disabled,
  the file is absent, or the term fails to decode.
  """
  @spec load(String.t(), keyword()) :: {:ok, record()} | {:error, :not_found}
  def load(session_id, opts \\ []) when is_binary(session_id) do
    case root(opts) do
      nil ->
        {:error, :not_found}

      dir ->
        case read_term(session_path(dir, session_id)) do
          {:ok, %{session_id: _, messages: _, updated_at: _} = record} -> {:ok, record}
          _ -> {:error, :not_found}
        end
    end
  end

  @doc """
  Lists every persisted session as an index `summary`, most-recently-updated
  first. Undecodable term files are skipped (logged), not raised — one stale
  entry must not blank the whole index.
  """
  @spec list(keyword()) :: [summary()]
  def list(opts \\ []) do
    case root(opts) do
      nil ->
        []

      dir ->
        case File.ls(dir) do
          {:ok, files} ->
            files
            |> Enum.filter(&String.ends_with?(&1, ".term"))
            |> Enum.map(&read_term(Path.join(dir, &1)))
            |> Enum.flat_map(&summarize/1)
            |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})

          {:error, :enoent} ->
            []

          {:error, reason} ->
            Logger.warning("harness chat store: cannot list #{dir}: #{inspect(reason)}")
            []
        end
    end
  end

  # Derives a recognizable label from a session's messages — the first user
  # message text, truncated, or "New chat" when none exists yet. Exposed (not
  # `defp`) so `Harness.Dashboard.ChatLive` labels live sessions with the same
  # rule it labels persisted ones; `@doc false` keeps it off the public surface.
  @doc false
  @spec derive_label([map()]) :: String.t()
  def derive_label(messages) do
    Enum.find_value(messages, "New chat", fn
      %{role: :user, content: text} when is_binary(text) -> truncate_label(text)
      %{"role" => "user", "content" => text} when is_binary(text) -> truncate_label(text)
      _ -> nil
    end)
  end

  @spec summarize({:ok, term()} | {:error, term()}) :: [summary()]
  defp summarize({:ok, %{session_id: id, messages: messages, updated_at: %DateTime{} = updated_at}}) do
    [
      %{
        session_id: id,
        label: derive_label(messages),
        message_count: length(messages),
        updated_at: updated_at
      }
    ]
  end

  defp summarize(_), do: []

  @spec truncate_label(String.t()) :: String.t()
  defp truncate_label(text) do
    trimmed = text |> String.trim() |> String.replace(~r/\s+/, " ")

    cond do
      trimmed == "" -> "New chat"
      String.length(trimmed) <= 60 -> trimmed
      true -> String.slice(trimmed, 0, 60) <> "…"
    end
  end

  @spec session_path(String.t(), String.t()) :: String.t()
  defp session_path(dir, session_id) do
    path = Path.expand(Path.join(dir, Base.url_encode64(session_id, padding: false) <> ".term"))
    root_with_separator = dir <> "/"

    if path == dir or String.starts_with?(path, root_with_separator) do
      path
    else
      raise ArgumentError, "chat store path escaped root"
    end
  end

  # Write to a `.tmp` sibling then atomically rename (POSIX, same filesystem):
  # a concurrent `list/1` never observes a half-written term file.
  # sobelow_skip ["Traversal.FileModule"]
  @spec write_term(String.t(), term()) :: :ok | {:error, term()}
  defp write_term(path, term) do
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, :erlang.term_to_binary(term)) do
      File.rename(tmp, path)
    end
  end

  # Decodes with [:safe]; only ever reads harness-owned files under the root.
  # sobelow_skip ["Traversal.FileModule", "Misc.BinToTerm"]
  @spec read_term(String.t()) :: {:ok, term()} | {:error, term()}
  defp read_term(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, :erlang.binary_to_term(body, [:safe])}
      {:error, reason} -> {:error, reason}
    end
  rescue
    ArgumentError -> {:error, {:invalid_term_file, path}}
  end

  # nil ⇒ store disabled; otherwise an expanded absolute root directory.
  @spec root(keyword()) :: String.t() | nil
  defp root(opts) do
    case Keyword.get(opts, :root, configured_root()) do
      false -> nil
      nil -> nil
      path when is_binary(path) -> Path.expand(path)
    end
  end

  @spec configured_root() :: String.t() | false | nil
  defp configured_root do
    case Application.get_env(:harness, :chat_store, root: @default_root) do
      false -> false
      nil -> nil
      opts when is_list(opts) -> Keyword.get(opts, :root, @default_root)
    end
  end
end
