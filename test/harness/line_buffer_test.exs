defmodule Harness.LineBufferTest do
  use ExUnit.Case, async: true

  alias Harness.LineBuffer

  doctest LineBuffer

  describe "split/2" do
    test "empty chunk buffers nothing and emits no complete lines" do
      assert {[], ""} = LineBuffer.split("", "")
    end

    test "empty chunk preserves an existing partial buffer verbatim" do
      assert {[], "partial"} = LineBuffer.split("partial", "")
    end

    test "a chunk with no newline buffers all bytes and emits no lines" do
      assert {[], "no newline here"} = LineBuffer.split("", "no newline here")
    end

    test "no-newline chunk appends onto the existing buffer" do
      assert {[], "head and tail"} = LineBuffer.split("head ", "and tail")
    end

    test "multiple complete lines plus a partial tail" do
      assert {["a", "b", "c"], "tail"} = LineBuffer.split("", "a\nb\nc\ntail")
    end

    test "the leading partial buffer joins the first complete line" do
      assert {["partial line", "second"], "third"} =
               LineBuffer.split("partial", " line\nsecond\nthird")
    end

    test "a chunk ending exactly on a newline leaves an empty rest buffer" do
      assert {["a", "b"], ""} = LineBuffer.split("", "a\nb\n")
    end

    test "an empty line between newlines is preserved as an empty complete line" do
      assert {["a", "", "b"], ""} = LineBuffer.split("", "a\n\nb\n")
    end

    test "accepts iodata chunks, not just binaries" do
      assert {["one", "two"], "three"} = LineBuffer.split("", ["one", "\n", ["two", "\nthree"]])
    end
  end

  describe "take_remainder/1" do
    test "an empty buffer drains to no lines and an empty rest" do
      assert {[], ""} = LineBuffer.take_remainder("")
    end

    test "a leftover buffer drains as a single final line and clears the buffer" do
      assert {[~s({"type":"result"})], ""} = LineBuffer.take_remainder(~s({"type":"result"}))
    end
  end
end
