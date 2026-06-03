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

  describe "write_file/2 + read_file/1" do
    @tag :tmp_dir
    test "round-trips a term through a file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "record.term")
      term = %{session_id: "abc", messages: [%{role: :user, content: "hi"}]}

      assert :ok = TermCodec.write_file(path, term)
      assert {:ok, ^term} = TermCodec.read_file(path)
    end

    @tag :tmp_dir
    test "write_file/2 creates missing parent directories", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "deeply", "nested", "record.term"])

      assert :ok = TermCodec.write_file(path, :payload)
      assert {:ok, :payload} = TermCodec.read_file(path)
    end

    @tag :tmp_dir
    test "write_file/2 leaves no .tmp sibling behind", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "record.term")

      assert :ok = TermCodec.write_file(path, %{a: 1})
      refute File.exists?(path <> ".tmp")
    end

    @tag :tmp_dir
    test "write_file/2 atomically replaces an existing file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "record.term")

      assert :ok = TermCodec.write_file(path, :first)
      assert :ok = TermCodec.write_file(path, :second)
      assert {:ok, :second} = TermCodec.read_file(path)
    end

    test "read_file/1 returns the posix error for a missing file" do
      assert {:error, :enoent} = TermCodec.read_file("/nonexistent/path/record.term")
    end

    @tag :tmp_dir
    test "read_file/1 returns {:error, {:invalid_term_file, path}} for garbage bytes", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "torn.term")
      File.write!(path, <<0, 1, 2, 3>>)

      assert {:error, {:invalid_term_file, ^path}} = TermCodec.read_file(path)
    end
  end
end
