defmodule Harness.ModelAvailabilityTest do
  use ExUnit.Case, async: false

  alias Harness.AgentAdapter.Claude
  alias Harness.AgentAdapter.Cursor
  alias Harness.AgentRegistry
  alias Harness.Config
  alias Harness.Dispatch
  alias Harness.ModelAvailability
  alias Harness.Notification.Event
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.Run
  alias Harness.SettingsStore
  alias Harness.Test.CaptureSink
  alias Harness.Test.SettingsStoreMemory

  @sample Path.expand("../fixtures/sample_roadmap", __DIR__)

  setup do
    AgentRegistry.reset()
    SettingsStoreMemory.reset()
    SettingsStore.put(ModelAvailability.blocks_key(), %{})
    SettingsStore.put(:model_catalogs, %{})
    SettingsStore.put(:model_catalog_static, %{})

    on_exit(fn ->
      Application.delete_env(:harness, :model_catalog_probe)
      Application.delete_env(:harness, :notification_sinks)
      Application.delete_env(:harness, :test_capture_pid)
      Application.delete_env(:harness, :oban_insert)
    end)

    :ok
  end

  describe "parse_catalog_line/1" do
    test "parses id - label with annotation metadata stripped" do
      entry = ModelAvailability.parse_catalog_line("composer-2.5-fast (default) - Composer 2.5 Fast")

      assert entry.id == "composer-2.5-fast"
      assert entry.label == "Composer 2.5 Fast"
      assert "default" in entry.annotations
    end

    test "ignores blank and comment lines" do
      assert :error = ModelAvailability.parse_catalog_line("")
      assert :error = ModelAvailability.parse_catalog_line("# comment")
    end
  end

  describe "parse_catalog_output/2 — per-agent formats" do
    test "grok bullet rows yield ids, dropping the (default) annotation and the header noise" do
      output = """
      You are logged in with grok.com.

      Default model: grok-build

      Available models:
        * grok-build (default)
        - grok-composer-2.5-fast
      """

      assert [
               %{id: "grok-build", label: "grok-build", annotations: ["default"]},
               %{id: "grok-composer-2.5-fast", label: "grok-composer-2.5-fast"}
             ] = ModelAvailability.parse_catalog_output(:grok, output)
    end

    test "pi table rows use the model column as id and the provider as label, skipping the header" do
      output = """
      provider   model                       context  max-out  thinking  images
      anthropic  claude-haiku-4-5-20251001   200K     64K      yes       yes
      openai     gpt-4o                      128K     16K      no        yes
      """

      assert [
               %{id: "claude-haiku-4-5-20251001", label: "anthropic"},
               %{id: "gpt-4o", label: "openai"}
             ] = ModelAvailability.parse_catalog_output(:pi, output)
    end

    test "dedupes repeated ids" do
      output = "  * grok-build (default)\n  - grok-build\n"
      assert [%{id: "grok-build"}] = ModelAvailability.parse_catalog_output(:grok, output)
    end
  end

  describe "block/unblock round-trip" do
    test "operator block persists and list_blocks surfaces it" do
      assert :ok =
               ModelAvailability.block_model("cursor", "claude-opus-4-8-thinking-high",
                 until: "2026-06-20T00:00:00Z",
                 reason: "out of tokens"
               )

      refute ModelAvailability.available?(:cursor, "claude-opus-4-8-thinking-high")
      assert %DateTime{} = ModelAvailability.blocked_until(:cursor, "claude-opus-4-8-thinking-high")

      assert {:ok, %{blocks: [block]}} = ModelAvailability.list_blocks()
      assert block.agent == "cursor"
      assert block.model == "claude-opus-4-8-thinking-high"
      assert block.source == "operator"

      assert :ok = ModelAvailability.unblock_model("cursor", "claude-opus-4-8-thinking-high")
      assert ModelAvailability.available?(:cursor, "claude-opus-4-8-thinking-high")
    end
  end

  describe "expiry" do
    test "a block with until in the past makes available?/2 true again" do
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()

      assert :ok =
               ModelAvailability.block_model("cursor", "composer-2.5", until: past, reason: "expired test")

      assert ModelAvailability.available?(:cursor, "composer-2.5")
      refute ModelAvailability.blocked_until(:cursor, "composer-2.5")
    end
  end

  describe "list_available/1" do
    test "omits blocked ids from the catalog" do
      install_catalog_probe()

      seed_static_catalog(:cursor, [
        %{id: "composer-2.5", label: "Composer", annotations: []},
        %{id: "claude-opus-4-8-thinking-high", label: "Opus", annotations: []}
      ])

      assert :ok = ModelAvailability.block_model("cursor", "claude-opus-4-8-thinking-high", reason: "blocked")

      assert [%{id: "composer-2.5"}] = ModelAvailability.list_available(:cursor)
    end

    test "returns catalog_unavailable for agents without a static list" do
      assert {:error, :catalog_unavailable} = ModelAvailability.list_available(:codex)
    end
  end

  describe "dispatch gate" do
    test "hard-rejects a blocked pair and returns the available list" do
      parent = self()
      install_catalog_probe()

      project = ProjectFixture.from_repo(@sample, name: "model-gate", roadmap_path: @sample)
      assert :ok = ProjectRegistry.register(project)

      seed_static_catalog(:cursor, [
        %{id: "composer-2.5", label: "Composer", annotations: []},
        %{id: "claude-opus-4-8-thinking-high", label: "Opus", annotations: []}
      ])

      assert :ok = Config.put({:agent_model, :cursor}, "claude-opus-4-8-thinking-high", "test")

      assert :ok =
               ModelAvailability.block_model("cursor", "claude-opus-4-8-thinking-high", reason: "token block")

      Application.put_env(:harness, :test_capture_pid, self())
      Application.put_env(:harness, :notification_sinks, [CaptureSink])

      Application.put_env(:harness, :oban_insert, fn changeset ->
        send(parent, :oban_insert_called)
        {:ok, Ecto.Changeset.apply_action!(changeset, :insert)}
      end)

      assert {:error, {:unavailable, :cursor, "claude-opus-4-8-thinking-high", available: available}} =
               Dispatch.task(project.name, "2", "cursor")

      assert "composer-2.5" in available
      refute_received :oban_insert_called

      assert_receive {:notify, %Event{type: :model_unavailable}}
    end
  end

  describe "reviewer-model gate" do
    test "rejects a blocked reviewer model before the reviewer Port spawns" do
      assert :ok = Config.put({:reviewer_model, :claude}, "claude-opus-4-8-thinking-high", "test")

      seed_static_catalog(:claude, [
        %{id: "claude-opus-4-8-thinking-high", label: "Opus", annotations: []},
        %{id: "claude-sonnet-4-6", label: "Sonnet", annotations: []}
      ])

      assert :ok =
               ModelAvailability.block_model("claude", "claude-opus-4-8-thinking-high", reason: "reviewer blocked")

      assert {:error, {:unavailable, :claude, "claude-opus-4-8-thinking-high", available: available}} =
               Run.reviewer_model_available?(%{reviewer_adapter: Claude})

      assert "claude-sonnet-4-6" in available
    end

    test "rejects a model-capable reviewer with no configured model" do
      assert {:error, {:model_required, :claude}} =
               Run.reviewer_model_available?(%{reviewer_adapter: Claude})
    end
  end

  describe "failure-capture" do
    test "records a block on a synthesized structured 429 settle" do
      signal = %{status: 429, retry_after_seconds: 120, model: "claude-opus-4-8-thinking-high"}

      assert :ok = AgentRegistry.mark_unavailable(Cursor, {:structured_quota, signal})

      assert {:ok, %{blocks: [block]}} = ModelAvailability.list_blocks()
      assert block.source == "failure"
      assert block.model == "claude-opus-4-8-thinking-high"
    end

    test "records a block on a string-keyed structured 429 payload" do
      signal = %{"status" => 429, "retry_after_seconds" => 90, "model" => "composer-2.5"}

      assert :ok = AgentRegistry.mark_unavailable(Cursor, {:structured_quota, signal})

      assert {:ok, %{blocks: [block]}} = ModelAvailability.list_blocks()
      assert block.source == "failure"
      assert block.model == "composer-2.5"
    end

    test "does not record a block on unstructured failure text" do
      assert :ok = AgentRegistry.mark_unavailable(Cursor, "429 rate limit")
      assert {:ok, %{blocks: []}} = ModelAvailability.list_blocks()
    end
  end

  defp install_catalog_probe do
    Application.put_env(:harness, :model_catalog_probe, fn agent, _executables ->
      case SettingsStore.fetch(:model_catalog_static) do
        {:ok, %{^agent => models}} when is_list(models) and models != [] -> {:ok, models}
        _ -> {:error, :catalog_unavailable}
      end
    end)
  end

  defp seed_static_catalog(agent, models) do
    current =
      case SettingsStore.fetch(:model_catalog_static) do
        {:ok, map} when is_map(map) -> map
        _ -> %{}
      end

    SettingsStore.put(:model_catalog_static, Map.put(current, agent, models))
  end
end
