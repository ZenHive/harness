defmodule Harness.AgentAdapter.RegistryTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Registry

  doctest Registry

  describe "resolve/1" do
    test "maps every harness adapter to {module, native render agent}" do
      # rmap's widened `delegate --to` renders natively for all six, so render
      # agent == the adapter atom — no claude-rendered two-step. This is the
      # value dispatch threads into Roadmap.ingest(agent: render_agent).
      assert Registry.resolve("claude") == {:ok, {AgentAdapter.Claude, :claude}}
      assert Registry.resolve("codex") == {:ok, {AgentAdapter.Codex, :codex}}
      assert Registry.resolve("cursor") == {:ok, {AgentAdapter.Cursor, :cursor}}
      assert Registry.resolve("grok") == {:ok, {AgentAdapter.Grok, :grok}}
      assert Registry.resolve("antigravity") == {:ok, {AgentAdapter.Antigravity, :antigravity}}
      assert Registry.resolve("pi") == {:ok, {AgentAdapter.Pi, :pi}}
    end

    test "rejects droid — renderable by rmap but no harness adapter" do
      assert Registry.resolve("droid") == {:error, {:unknown_adapter, "droid"}}
    end

    test "rejects an unknown name" do
      assert Registry.resolve("nope") == {:error, {:unknown_adapter, "nope"}}
    end
  end

  describe "delegatable?/1" do
    test "is true for every harness adapter" do
      for name <- ~w(claude codex cursor grok antigravity pi) do
        assert Registry.delegatable?(name), "expected #{name} to be delegatable"
      end
    end

    test "is false for a name with no harness adapter (droid)" do
      refute Registry.delegatable?("droid")
    end
  end
end
