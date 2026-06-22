defmodule Harness.Chat.Store.Memory do
  @moduledoc """
  In-memory ephemeral `Harness.Chat.Store` backend.

  Used when `:repo_enabled` is false. Sessions are available while the node is
  running and intentionally disappear on restart.
  """

  @behaviour Harness.Chat.Store

  alias Harness.Chat.Store
  alias Harness.Store.EtsScope

  @table __MODULE__
  @max_persisted_messages 200

  @impl Store
  @spec save(String.t(), [map()], keyword()) :: :ok
  def save(session_id, messages, opts) when is_binary(session_id) and is_list(messages) and is_list(opts) do
    record = %{
      session_id: session_id,
      messages: Enum.take(messages, -@max_persisted_messages),
      updated_at: DateTime.utc_now()
    }

    update(opts, &Map.put(&1, session_id, record))
  end

  @impl Store
  @spec load(String.t(), keyword()) :: {:ok, Store.session_record()} | {:error, :not_found}
  def load(session_id, opts) when is_binary(session_id) and is_list(opts) do
    case Map.fetch(read(opts), session_id) do
      {:ok, record} -> {:ok, record}
      :error -> {:error, :not_found}
    end
  end

  @impl Store
  @spec list(keyword()) :: [Store.summary()]
  def list(opts) when is_list(opts) do
    opts
    |> read()
    |> Map.values()
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
    |> Enum.map(fn %{session_id: id, messages: messages, updated_at: updated_at} ->
      %{session_id: id, label: Store.derive_label(messages), message_count: length(messages), updated_at: updated_at}
    end)
  end

  @doc false
  @spec reset(keyword()) :: :ok
  def reset(opts) when is_list(opts), do: EtsScope.reset(@table, opts)

  @spec update(keyword(), (map() -> map())) :: :ok
  defp update(opts, fun), do: EtsScope.update(@table, opts, %{}, fun)

  @spec read(keyword()) :: map()
  defp read(opts), do: EtsScope.read(@table, opts, %{})
end
