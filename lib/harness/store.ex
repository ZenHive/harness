defmodule Harness.Store do
  @moduledoc """
  Shared mechanics for pluggable store facades and their Postgres backends.

  Facades (`Harness.DepFreshnessStore`, `Harness.SuiteHealthStore`) dispatch to
  a configured backend given as `module`, `{module, opts}`, or `false`
  (disabled). Postgres backends rescue the same persistence error set.
  """

  @type store :: module() | {module(), keyword()} | false

  @persistence_errors [
    RuntimeError,
    DBConnection.ConnectionError,
    DBConnection.OwnershipError,
    Postgrex.Error,
    Ecto.ConstraintError,
    Ecto.StaleEntryError,
    Ecto.Query.CastError,
    Ecto.QueryError,
    Ecto.ChangeError,
    ArgumentError
  ]

  @doc "Invokes `function` on the configured backend; `false` is a no-op `:ok`."
  @spec dispatch(store(), atom(), [term()]) :: term()
  def dispatch(false, _function, _args), do: :ok

  def dispatch({module, opts}, function, args) when is_atom(module) and is_list(opts) do
    apply(module, function, args ++ [opts])
  end

  def dispatch(module, function, args) when is_atom(module) do
    apply(module, function, args ++ [[]])
  end

  @doc "Exception modules a Postgres store backend rescues as `{:error, e}`."
  @spec persistence_errors() :: [module()]
  def persistence_errors, do: @persistence_errors
end
