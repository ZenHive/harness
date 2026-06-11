defmodule Harness.TextTest do
  use ExUnit.Case, async: true

  alias Harness.Text

  doctest Text

  describe "valid_utf8_head/1" do
    test "returns valid input unchanged" do
      assert Text.valid_utf8_head("héllo") == "héllo"
    end

    test "returns empty input unchanged" do
      assert Text.valid_utf8_head(<<>>) == <<>>
    end

    test "drops a 4-byte codepoint cut at every split offset" do
      # "a" <> 🎉 (4 bytes) — cutting inside the emoji must trim back to "a".
      bin = "a🎉"

      for cap <- 2..4 do
        assert Text.valid_utf8_head(binary_part(bin, 0, cap)) == "a"
      end
    end

    test "trims to empty when no valid head exists" do
      assert Text.valid_utf8_head(<<0xFF>>) == <<>>
    end
  end

  describe "valid_utf8_tail/1" do
    test "returns valid input unchanged" do
      assert Text.valid_utf8_tail("héllo") == "héllo"
    end

    test "returns empty input unchanged" do
      assert Text.valid_utf8_tail(<<>>) == <<>>
    end

    test "drops a 4-byte codepoint cut at every split offset" do
      # 🎉 (4 bytes) <> "a" — a tail slice starting inside the emoji must trim
      # forward to "a".
      bin = "🎉a"

      for start <- 1..3 do
        assert Text.valid_utf8_tail(binary_part(bin, start, byte_size(bin) - start)) == "a"
      end
    end

    test "trims to empty when no valid tail exists" do
      assert Text.valid_utf8_tail(<<0xFF>>) == <<>>
    end
  end

  describe "placeholder/1" do
    test "maps nil to the (none) literal" do
      assert Text.placeholder(nil) == "(none)"
    end

    test "maps empty text to the (none) literal" do
      assert Text.placeholder("") == "(none)"
    end

    test "passes non-empty text through" do
      assert Text.placeholder(" ") == " "
      assert Text.placeholder("body") == "body"
    end
  end
end
