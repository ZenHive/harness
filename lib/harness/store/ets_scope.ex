defmodule Harness.Store.EtsScope do
  @moduledoc false
  # Shared ETS-backed, scope-keyed state substrate for the in-memory store
  # backends (`Harness.Chat.Store.Memory`, `Harness.ResultStore.Memory`) used when
  # `:repo_enabled` is false. Purely mechanical ETS reads/writes keyed by a
  # caller-supplied scope; the owning store supplies its `table` name and the
  # `empty` value to fall back to when no row exists yet, so the two backends no
  # longer carry their own copy of this boilerplate.

  @doc """
  Ensures the named `:set` table exists. Idempotent — a second call (e.g. from a
  concurrent process) is a no-op rather than an error.
  """
  @spec ensure_table(atom()) :: :ok
  def ensure_table(table) do
    _ = :ets.new(table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Derives the scope key from `opts` (`:scope`, then `:root`, then `:default`)."
  @spec scope(keyword()) :: term()
  def scope(opts), do: Keyword.get(opts, :scope, Keyword.get(opts, :root, :default))

  @doc "Reads the state stored under `opts`'s scope, or `empty` when no row exists."
  @spec read(atom(), keyword(), term()) :: term()
  def read(table, opts, empty) do
    ensure_table(table)

    case :ets.lookup(table, scope(opts)) do
      [{_scope, state}] -> state
      [] -> empty
    end
  end

  @doc "Deletes the row under `opts`'s scope."
  @spec reset(atom(), keyword()) :: :ok
  def reset(table, opts) do
    ensure_table(table)
    :ets.delete(table, scope(opts))
    :ok
  end

  @doc "Replaces the state under `opts`'s scope with `fun.(current_or_empty)`."
  @spec update(atom(), keyword(), term(), (term() -> term())) :: :ok
  def update(table, opts, empty, fun) when is_function(fun, 1) do
    ensure_table(table)
    :ets.insert(table, {scope(opts), fun.(read(table, opts, empty))})
    :ok
  end
end
