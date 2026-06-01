defmodule TinyTest do
  use ExUnit.Case, async: true

  test "encodes a map" do
    assert {:ok, "{\"a\":1}"} = Tiny.encode(%{a: 1})
  end
end
