defmodule Harness.Chat.Store.File do
  @moduledoc """
  File-backed `Harness.Chat.Store` implementation.
  """

  @behaviour Harness.Chat.Store

  alias Harness.Chat.Store
  alias Harness.TermCodec

  require Logger

  @default_root "~/.harness/chats"
  @max_persisted_messages 200

  @impl Store
  @spec save(String.t(), [map()], keyword()) :: :ok | {:error, term()}
  def save(session_id, messages, opts) when is_binary(session_id) and is_list(messages) and is_list(opts) do
    case root(opts) do
      nil ->
        :ok

      dir ->
        record = %{
          session_id: session_id,
          messages: Enum.take(messages, -@max_persisted_messages),
          updated_at: DateTime.utc_now()
        }

        TermCodec.write_file(session_path(dir, session_id), record)
    end
  end

  @impl Store
  @spec load(String.t(), keyword()) :: {:ok, Store.record()} | {:error, :not_found}
  def load(session_id, opts) when is_binary(session_id) and is_list(opts) do
    case root(opts) do
      nil ->
        {:error, :not_found}

      dir ->
        case TermCodec.read_file(session_path(dir, session_id)) do
          {:ok, %{session_id: _, messages: _, updated_at: _} = record} -> {:ok, record}
          _ -> {:error, :not_found}
        end
    end
  end

  @impl Store
  @spec list(keyword()) :: [Store.summary()]
  def list(opts) when is_list(opts) do
    case root(opts) do
      nil ->
        []

      dir ->
        case File.ls(dir) do
          {:ok, files} ->
            files
            |> Enum.filter(&String.ends_with?(&1, ".term"))
            |> Enum.flat_map(&summarize(TermCodec.read_file(Path.join(dir, &1))))
            |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})

          {:error, :enoent} ->
            []

          {:error, reason} ->
            Logger.warning("harness chat store: cannot list #{dir}: #{inspect(reason)}")
            []
        end
    end
  end

  @spec summarize({:ok, term()} | {:error, term()}) :: [Store.summary()]
  defp summarize({:ok, %{session_id: id, messages: messages, updated_at: %DateTime{} = updated_at}}) do
    [
      %{
        session_id: id,
        label: Store.derive_label(messages),
        message_count: length(messages),
        updated_at: updated_at
      }
    ]
  end

  defp summarize(_), do: []

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
