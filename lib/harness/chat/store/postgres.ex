defmodule Harness.Chat.Store.Postgres do
  @moduledoc """
  Postgres-backed `Harness.Chat.Store` implementation.
  """

  @behaviour Harness.Chat.Store

  import Ecto.Query

  alias Harness.Chat.Store.Postgres.ChatSession
  alias Harness.Repo

  require Logger

  @max_persisted_messages 200

  @impl Harness.Chat.Store
  @spec save(String.t(), [map()], keyword()) :: :ok | {:error, term()}
  def save(session_id, messages, opts) when is_binary(session_id) and is_list(messages) and is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)
    capped = Enum.take(messages, -@max_persisted_messages)

    attrs = %{
      session_id: session_id,
      messages: capped
    }

    schema = %ChatSession{session_id: session_id}
    changeset = ChatSession.changeset(schema, attrs)

    try do
      case repo.insert(changeset, on_conflict: :replace_all, conflict_target: :session_id) do
        {:ok, _} -> :ok
        {:error, cs} -> {:error, {:changeset, cs.errors}}
      end
    rescue
      e -> {:error, e}
    end
  end

  @impl Harness.Chat.Store
  @spec load(String.t(), keyword()) :: {:ok, Harness.Chat.Store.record()} | {:error, :not_found}
  def load(session_id, opts) when is_binary(session_id) and is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)

    try do
      case repo.get(ChatSession, session_id) do
        nil ->
          {:error, :not_found}

        %ChatSession{messages: messages, updated_at: updated_at} ->
          decoded = decode_messages(messages)
          {:ok, %{session_id: session_id, messages: decoded, updated_at: DateTime.from_naive!(updated_at, "Etc/UTC")}}
      end
    rescue
      _ -> {:error, :not_found}
    end
  end

  @impl Harness.Chat.Store
  @spec list(keyword()) :: [Harness.Chat.Store.summary()]
  def list(opts) when is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)

    try do
      query =
        from s in ChatSession,
          order_by: [desc: s.updated_at]

      rows = repo.all(query)

      Enum.map(rows, fn %ChatSession{session_id: id, messages: messages, updated_at: updated_at} ->
        decoded = decode_messages(messages)
        %{
          session_id: id,
          label: Harness.Chat.Store.derive_label(decoded),
          message_count: length(decoded),
          updated_at: DateTime.from_naive!(updated_at, "Etc/UTC")
        }
      end)
    rescue
      e ->
        Logger.warning("harness chat store: cannot list from db: #{inspect(e)}")
        []
    end
  end

  # --- Helpers to restore atom keys and atom role values after JSON serialization ---

  @spec decode_messages([map()] | nil) :: [map()]
  defp decode_messages(nil), do: []

  defp decode_messages(messages) when is_list(messages) do
    Enum.map(messages, &decode_message/1)
  end

  @spec decode_message(term()) :: term()
  defp decode_message(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_binary(k), do: String.to_atom(k), else: k
      value = decode_message_value(key, v)
      {key, value}
    end)
  end

  defp decode_message(list) when is_list(list) do
    Enum.map(list, &decode_message/1)
  end

  defp decode_message(other), do: other

  @spec decode_message_value(atom() | String.t(), term()) :: term()
  defp decode_message_value(:role, "user"), do: :user
  defp decode_message_value(:role, "assistant"), do: :assistant
  defp decode_message_value(_, value), do: decode_message(value)
end
