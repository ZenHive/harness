defmodule Harness.JSONSafeTest do
  use ExUnit.Case, async: true

  alias Harness.JSONSafe

  doctest JSONSafe

  defmodule Sample do
    @moduledoc false
    defstruct [:name, :count]
  end

  describe "encode/2 — shared backbone (both presets)" do
    for {label, opts_fun} <- [{"chat", :chat_opts}, {"mcp", :mcp_opts}] do
      @opts apply(JSONSafe, opts_fun, [])

      test "#{label}: passes through strings, numbers, and lists unchanged" do
        assert JSONSafe.encode("hello", @opts) == "hello"
        assert JSONSafe.encode(42, @opts) == 42
        assert JSONSafe.encode(3.5, @opts) == 3.5
        assert JSONSafe.encode([1, "a", 2], @opts) == [1, "a", 2]
      end

      test "#{label}: stringifies non-leaf atoms" do
        assert JSONSafe.encode(:ok, @opts) == "ok"
      end

      test "#{label}: stringifies atom and binary map keys, recurses on values" do
        assert JSONSafe.encode(%{:a => 1, "b" => :two}, @opts) == %{"a" => 1, "b" => "two"}
      end

      test "#{label}: nested maps recurse" do
        assert JSONSafe.encode(%{outer: %{inner: :v}}, @opts) == %{"outer" => %{"inner" => "v"}}
      end

      test "#{label}: structs become string-keyed maps (no __struct__ field)" do
        encoded = JSONSafe.encode(%Sample{name: "x", count: 2}, @opts)
        assert encoded == %{"name" => "x", "count" => 2}
        refute Map.has_key?(encoded, "__struct__")
      end
    end
  end

  describe "encode/2 — chat preset divergences" do
    @chat JSONSafe.chat_opts()

    test "preserves nil and booleans" do
      assert JSONSafe.encode(nil, @chat) == nil
      assert JSONSafe.encode(true, @chat) == true
      assert JSONSafe.encode(false, @chat) == false
    end

    test "inspects tuples to a string" do
      assert JSONSafe.encode({:ok, 1}, @chat) == "{:ok, 1}"
    end

    test "renders DateTime as ISO-8601" do
      {:ok, dt, _} = DateTime.from_iso8601("2026-06-03T10:00:00Z")
      assert JSONSafe.encode(dt, @chat) == "2026-06-03T10:00:00Z"
    end

    test "inspects pids and references" do
      assert JSONSafe.encode(self(), @chat) == inspect(self())
      ref = make_ref()
      assert JSONSafe.encode(ref, @chat) == inspect(ref)
    end
  end

  describe "encode/2 — mcp preset divergences" do
    @mcp JSONSafe.mcp_opts()

    test "stringifies nil and booleans" do
      assert JSONSafe.encode(nil, @mcp) == "nil"
      assert JSONSafe.encode(true, @mcp) == "true"
      assert JSONSafe.encode(false, @mcp) == "false"
    end

    test "flattens tuples to a list, recursing on elements" do
      assert JSONSafe.encode({:ok, %{a: 1}}, @mcp) == ["ok", %{"a" => 1}]
    end

    test "renders DateTime via the generic struct path (no special-casing)" do
      {:ok, dt, _} = DateTime.from_iso8601("2026-06-03T10:00:00Z")
      encoded = JSONSafe.encode(dt, @mcp)
      assert is_map(encoded)
      assert encoded["year"] == 2026
      assert encoded["calendar"] == "Elixir.Calendar.ISO"
    end

    test "inspects pids and references" do
      assert JSONSafe.encode(self(), @mcp) == inspect(self())
    end
  end

  describe "encode/2 — Jason round-trip" do
    test "every encoded value is JSON-encodable under both presets" do
      term = %{status: :ok, items: [{:a, 1}], when: nil, depth: 3}

      assert {:ok, _} = Jason.encode(JSONSafe.encode(term, JSONSafe.chat_opts()))
      assert {:ok, _} = Jason.encode(JSONSafe.encode(term, JSONSafe.mcp_opts()))
    end
  end
end
