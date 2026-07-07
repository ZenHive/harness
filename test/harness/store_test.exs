defmodule Harness.StoreTest do
  use ExUnit.Case, async: true

  alias Harness.Store

  defmodule Backend do
    @moduledoc false
    @spec echo(term(), keyword()) :: {:echoed, term(), keyword()}
    def echo(arg, opts), do: {:echoed, arg, opts}
  end

  describe "dispatch/3" do
    test "a disabled store (false) is a no-op :ok" do
      assert Store.dispatch(false, :echo, [:ignored]) == :ok
    end

    test "a {module, opts} store appends the opts to the call" do
      assert Store.dispatch({Backend, scope: :test}, :echo, [:payload]) ==
               {:echoed, :payload, [scope: :test]}
    end

    test "a bare module store calls with empty opts" do
      assert Store.dispatch(Backend, :echo, [:payload]) == {:echoed, :payload, []}
    end
  end

  describe "persistence_errors/0" do
    test "lists the exception modules Postgres backends rescue" do
      errors = Store.persistence_errors()

      assert RuntimeError in errors
      assert DBConnection.ConnectionError in errors
      assert Postgrex.Error in errors
      assert Ecto.ConstraintError in errors
      assert ArgumentError in errors
    end
  end
end
