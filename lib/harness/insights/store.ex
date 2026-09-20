defmodule Harness.Insights.Store do
  @moduledoc "Transactional observation documents; ephemeral when the repository is disabled."
  import Ecto.Query

  alias Harness.Insights.Document
  alias Harness.Repo
  alias Harness.Store.EtsHeir

  @table __MODULE__

  @doc "Whether observations survive a BEAM restart."
  @spec persistent?() :: boolean()
  def persistent?, do: Application.get_env(:harness, :repo_enabled, true)

  @doc "Fetches one observation document."
  @spec get(String.t()) :: map() | nil
  def get(id) do
    if persistent?() do
      case Repo.get(Document, id) do
        nil -> nil
        doc -> doc.data
      end
    else
      ensure_table()

      case :ets.lookup(@table, id) do
        [{^id, _kind, data, _time}] -> data
        [] -> nil
      end
    end
  end

  @doc "Lists a bounded page, newest revision first."
  @spec list(String.t(), non_neg_integer(), pos_integer(), map()) :: [map()]
  def list(kind, offset \\ 0, limit \\ 50, filters \\ %{}) when offset >= 0 and limit in 1..100 do
    if persistent?() do
      Repo.all(
        from d in Document,
          where: d.kind == ^kind and fragment("? @> ?", d.data, type(^filters, :map)),
          order_by: [desc: d.updated_at, desc: d.id],
          offset: ^offset,
          limit: ^limit,
          select: d.data
      )
    else
      ensure_table()

      @table
      |> :ets.tab2list()
      |> Enum.filter(&(elem(&1, 1) == kind and matches?(elem(&1, 2), filters)))
      |> Enum.sort_by(&{elem(&1, 3), elem(&1, 0)}, :desc)
      |> Enum.drop(offset)
      |> Enum.take(limit)
      |> Enum.map(&elem(&1, 2))
    end
  end

  @spec matches?(map(), map()) :: boolean()
  defp matches?(data, filters) do
    Enum.all?(filters, fn {key, values} -> Enum.all?(values, &(&1 in Map.get(data, key, []))) end)
  end

  @doc "Writes documents atomically, including the successful evidence checkpoint."
  @spec put_many([{String.t(), String.t(), map()}]) :: :ok | {:error, term()}
  def put_many(documents) do
    now = DateTime.utc_now()
    write = fn -> insert_documents(documents) end

    if persistent?() do
      case Repo.transaction(write) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      ensure_table()
      true = :ets.insert(@table, Enum.map(documents, fn {id, kind, data} -> {id, kind, data, now} end))
      :ok
    end
  end

  @doc "Serializes passes across nodes using a connection-scoped database lock."
  @spec serialized((-> term())) :: term()
  def serialized(fun) do
    if persistent?() do
      Repo.checkout(fn -> locked(fun) end, timeout: 240_000)
    else
      :global.trans({__MODULE__, self()}, fun)
    end
  end

  @spec insert_documents([tuple()]) :: :ok
  defp insert_documents(documents), do: Enum.each(documents, &insert_document/1)

  @spec insert_document({String.t(), String.t(), map()}) :: Document.t()
  defp insert_document({id, kind, data}) do
    Repo.insert!(%Document{id: id, kind: kind, data: data},
      on_conflict: {:replace, [:data, :updated_at]},
      conflict_target: :id
    )
  end

  @spec locked((-> term())) :: term()
  defp locked(fun) do
    %{rows: [[locked]]} = Repo.query!("SELECT pg_try_advisory_lock(443, 1)")

    if locked do
      try do
        fun.()
      after
        Repo.query!("SELECT pg_advisory_unlock(443, 1)")
      end
    else
      {:error, :already_observing}
    end
  end

  @spec ensure_table() :: :ok
  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      heir = EtsHeir.pid(Harness.Insights.Store.Heir)

      try do
        :ets.new(@table, [:named_table, :public, :set, {:heir, heir, nil}])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end
end
