defmodule Harness.PlaybooksTest do
  use ExUnit.Case, async: true

  alias Harness.Chat.Tools
  alias Harness.Playbooks

  @expected_names ~w(dispatch-single-task dispatch-bundle ab-adapter-compare audit-grade-fix)

  describe "list/0" do
    test "returns the full catalog as JSON-native summary maps" do
      catalog = Playbooks.list()

      assert Enum.map(catalog, & &1.name) == @expected_names

      for entry <- catalog do
        assert is_binary(entry.name) and entry.name != ""
        assert is_binary(entry.title) and entry.title != ""
        assert is_binary(entry.summary) and entry.summary != ""
        # Summaries are descriptors, not the recipe — the body lives behind get/1.
        refute Map.has_key?(entry, :body)
      end
    end
  end

  describe "get/1" do
    test "returns the catalog entry plus the embedded markdown body" do
      assert {:ok, playbook} = Playbooks.get("dispatch-single-task")
      assert playbook.name == "dispatch-single-task"
      assert playbook.title == "Dispatch a single roadmap task"
      assert is_binary(playbook.summary) and playbook.summary != ""
      # The body is the full recipe and cites the concrete tools it drives.
      assert playbook.body =~ "# Dispatch a single roadmap task"
      assert playbook.body =~ "roadmap__ingest"
      assert playbook.body =~ "supervisor__start_run"
    end

    test "every catalogued playbook resolves to a non-empty body" do
      for name <- @expected_names do
        assert {:ok, %{body: body}} = Playbooks.get(name)
        assert is_binary(body) and String.length(body) > 100
      end
    end

    test "errors with :unknown_playbook for an unknown slug" do
      assert {:error, {:unknown_playbook, "nope"}} = Playbooks.get("nope")
    end
  end

  describe "MCP surface integration" do
    test "playbooks tools are exposed via the manifest" do
      names = Enum.map(Harness.Manifest.mcp_tools(), & &1.name)
      assert "playbooks__list" in names
      assert "playbooks__get" in names
    end

    test "playbooks__get dispatches positionally through the chat tool registry" do
      registry = Tools.build()

      assert {:ok, {:ok, playbook}} =
               Tools.dispatch(registry, "playbooks__get", %{"name" => "dispatch-bundle"})

      assert playbook.name == "dispatch-bundle"
      assert playbook.body =~ "batch__dispatch"
    end

    test "playbooks__list dispatches through the chat tool registry" do
      registry = Tools.build()

      assert {:ok, catalog} = Tools.dispatch(registry, "playbooks__list", %{})
      assert Enum.map(catalog, & &1.name) == @expected_names
    end
  end
end
