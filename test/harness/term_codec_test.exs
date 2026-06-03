defmodule Harness.TermCodecTest do
  use ExUnit.Case, async: true

  alias Harness.TermCodec

  doctest TermCodec

  describe "safe_binary_to_term/1" do
    test "round-trips a serialized map" do
      term = %{agent: :claude, score: 0.9, items: [1, 2, 3]}
      assert {:ok, ^term} = TermCodec.safe_binary_to_term(:erlang.term_to_binary(term))
    end

    test "round-trips a serialized struct" do
      term = %{__struct__: URI, host: "example.com"}
      assert {:ok, ^term} = TermCodec.safe_binary_to_term(:erlang.term_to_binary(term))
    end

    test "round-trips a nested tuple/list term" do
      term = {:ok, [%{a: 1}, {:nested, true}]}
      assert {:ok, ^term} = TermCodec.safe_binary_to_term(:erlang.term_to_binary(term))
    end

    test "returns {:error, :invalid_term} for a garbage binary" do
      assert {:error, :invalid_term} = TermCodec.safe_binary_to_term(<<0, 1, 2, 3>>)
    end

    test "returns {:error, :invalid_term} for a truncated term binary" do
      <<head::binary-size(4), _rest::binary>> = :erlang.term_to_binary(%{a: 1})
      assert {:error, :invalid_term} = TermCodec.safe_binary_to_term(head)
    end

    test "returns {:error, :invalid_term} for an empty binary" do
      assert {:error, :invalid_term} = TermCodec.safe_binary_to_term("")
    end
  end
end
