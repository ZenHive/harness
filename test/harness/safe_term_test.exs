defmodule Harness.SafeTermTest do
  use ExUnit.Case, async: false

  alias Harness.SafeTerm

  test "restores a harness-owned ETF atom absent from the reading node" do
    name = "safe_term_cold_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end

    payload = <<131, 100, byte_size(name)::16, name::binary>>

    assert_raise ArgumentError, fn -> :erlang.binary_to_term(payload, [:safe]) end
    assert {:ok, atom} = SafeTerm.decode(payload)
    assert Atom.to_string(atom) == name
  end

  test "rejects malformed ETF" do
    assert {:error, :invalid_term} = SafeTerm.decode(<<131, 255>>)
  end

  test "application boot eagerly loads every harness module used by persisted structs" do
    assert Enum.all?(Application.spec(:harness, :modules), &Code.ensure_loaded?/1)
    assert Code.ensure_loaded?(Harness.Project)
  end
end
