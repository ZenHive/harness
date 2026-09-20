defmodule Harness.Store.Documents do
  @moduledoc "Shared transactional document storage with isolated schemas, ETS tables and locks."
  import Ecto.Query

  alias Harness.Repo
  alias Harness.Store.EtsHeir

  @type config :: %{
          schema: module(),
          table: atom(),
          heir: atom(),
          lock: integer(),
          timeout: pos_integer(),
          busy: atom()
        }

  @doc "Defines a document store facade with its own schema, table, heir and advisory lock."
  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(opts) do
    quote do
      alias Harness.Store.Documents

      @config unquote(opts) |> Map.new() |> Map.put(:table, __MODULE__)

      @doc "Whether documents survive a BEAM restart."
      @spec persistent?() :: boolean()
      defdelegate persistent?(), to: Documents

      @doc "Fetches one document."
      @spec get(String.t()) :: map() | nil
      def get(id), do: Documents.get(@config, id)

      @doc "Lists a bounded page, newest revision first."
      @spec list(String.t(), non_neg_integer(), pos_integer(), map()) :: [map()]
      def list(kind, offset \\ 0, limit \\ 50, filters \\ %{}), do: Documents.list(@config, kind, offset, limit, filters)

      @doc "Writes documents atomically, including the successful evidence checkpoint."
      @spec put_many([{String.t(), String.t(), map()}]) :: :ok | {:error, term()}
      def put_many(documents), do: Documents.put_many(@config, documents)

      @doc "Serializes passes across nodes using a connection-scoped database lock."
      @spec serialized((-> term())) :: term()
      def serialized(fun), do: Documents.serialized(@config, fun)
    end
  end

  @doc "Whether documents survive a BEAM restart."
  @spec persistent?() :: boolean()
  def persistent?, do: Application.get_env(:harness, :repo_enabled, true)

  @doc "Fetches one document."
  @spec get(config(), String.t()) :: map() | nil
  def get(config, id) do
    if persistent?() do
      case Repo.get(config.schema, id) do
        nil -> nil
        doc -> doc.data
      end
    else
      ensure_table(config)

      case :ets.lookup(config.table, id) do
        [{^id, _kind, data, _time}] -> data
        [] -> nil
      end
    end
  end

  @doc "Lists a bounded page, newest revision first."
  @spec list(config(), String.t(), non_neg_integer(), pos_integer(), map()) :: [map()]
  def list(config, kind, offset, limit, filters) when offset >= 0 and limit in 1..100 do
    if persistent?() do
      Repo.all(
        from d in config.schema,
          where: d.kind == ^kind and fragment("? @> ?", d.data, type(^filters, :map)),
          order_by: [desc: d.updated_at, desc: d.id],
          offset: ^offset,
          limit: ^limit,
          select: d.data
      )
    else
      ensure_table(config)

      config.table
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
  @spec put_many(config(), [{String.t(), String.t(), map()}]) :: :ok | {:error, term()}
  def put_many(config, documents) do
    now = DateTime.utc_now()
    write = fn -> insert_documents(config, documents) end

    if persistent?() do
      case Repo.transaction(write) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      ensure_table(config)
      true = :ets.insert(config.table, Enum.map(documents, fn {id, kind, data} -> {id, kind, data, now} end))
      :ok
    end
  end

  @doc "Serializes passes across nodes using a connection-scoped database lock."
  @spec serialized(config(), (-> term())) :: term()
  def serialized(config, fun) do
    if persistent?() do
      Repo.checkout(fn -> locked(config, fun) end, timeout: config.timeout)
    else
      :global.trans({config.table, self()}, fun)
    end
  end

  @spec insert_documents(config(), [tuple()]) :: :ok
  defp insert_documents(config, documents), do: Enum.each(documents, &insert_document(config, &1))

  @spec insert_document(config(), {String.t(), String.t(), map()}) :: struct()
  defp insert_document(config, {id, kind, data}) do
    Repo.insert!(struct!(config.schema, id: id, kind: kind, data: data),
      on_conflict: {:replace, [:data, :updated_at]},
      conflict_target: :id
    )
  end

  @spec locked(config(), (-> term())) :: term()
  defp locked(config, fun) do
    %{rows: [[locked]]} = Repo.query!("SELECT pg_try_advisory_lock($1, 1)", [config.lock])

    if locked do
      try do
        fun.()
      after
        Repo.query!("SELECT pg_advisory_unlock($1, 1)", [config.lock])
      end
    else
      {:error, config.busy}
    end
  end

  @spec ensure_table(config()) :: :ok
  defp ensure_table(config) do
    if :ets.whereis(config.table) == :undefined do
      heir = EtsHeir.pid(config.heir)

      try do
        :ets.new(config.table, [:named_table, :public, :set, {:heir, heir, nil}])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end
end
