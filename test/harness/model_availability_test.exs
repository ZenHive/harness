defmodule Harness.ModelAvailabilityTest do
  # async: false because tests mutate AgentRegistry, ProjectRegistry, and app env seams.
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
  @future_block_seconds 3_600

  setup do
    prior_agent_model = Application.get_env(:harness, :agent_model)
    prior_reviewer_model = Application.get_env(:harness, :reviewer_model)

    Application.delete_env(:harness, :agent_model)
    Application.delete_env(:harness, :reviewer_model)

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
      restore_env(:agent_model, prior_agent_model)
      restore_env(:reviewer_model, prior_reviewer_model)
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

      Default model: grok-4.5

      Available models:
        * grok-4.5 (default)
        - grok-composer-2.5-fast
      """

      assert [
               %{id: "grok-4.5", label: "grok-4.5", annotations: ["default"]},
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
      output = "  * grok-4.5 (default)\n  - grok-4.5\n"
      assert [%{id: "grok-4.5"}] = ModelAvailability.parse_catalog_output(:grok, output)
    end

    test "antigravity display labels map to dash-form ids and dedupe shared ids" do
      output = """
      Fetching available models...
      Gemini 3.5 Flash (Low)
      Gemini 3.5 Flash (Medium)
      Gemini 3.1 Pro (High)
      Claude Sonnet 4.6 (Thinking)
      GPT-OSS 120B
      """

      assert [
               %{id: "gemini-3.5-flash", label: "Gemini 3.5 Flash (Low)"},
               %{id: "gemini-3.1-pro", label: "Gemini 3.1 Pro (High)"},
               %{id: "claude-sonnet-4-5", label: "Claude Sonnet 4.6 (Thinking)"},
               %{id: "gpt-oss-120b", label: "GPT-OSS 120B"}
             ] = ModelAvailability.parse_catalog_output(:antigravity, output)
    end

    test "codex JSON yields visibility=list slugs, dropping hidden internal models" do
      # Real `codex debug models` shape (trimmed to the parsed fields), 2026-07-10 —
      # includes the GPT-5.6 Sol/Terra/Luna frontier family.
      output =
        ~s({"models":[) <>
          ~s({"slug":"gpt-5.5","display_name":"GPT-5.5","visibility":"list"},) <>
          ~s({"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","visibility":"list"},) <>
          ~s({"slug":"gpt-5.6-terra","display_name":"GPT-5.6-Terra","visibility":"list"},) <>
          ~s({"slug":"gpt-5.6-luna","display_name":"GPT-5.6-Luna","visibility":"list"},) <>
          ~s({"slug":"gpt-5.4","display_name":"GPT-5.4","visibility":"list"},) <>
          ~s({"slug":"gpt-5.4-mini","display_name":"GPT-5.4-Mini","visibility":"list"},) <>
          ~s({"slug":"gpt-5.3-codex-spark","display_name":"GPT-5.3-Codex-Spark","visibility":"list"},) <>
          ~s({"slug":"codex-auto-review","display_name":"Codex Auto Review","visibility":"hide"}]})

      assert [
               %{id: "gpt-5.5", label: "GPT-5.5", annotations: []},
               %{id: "gpt-5.6-sol", label: "GPT-5.6-Sol", annotations: []},
               %{id: "gpt-5.6-terra", label: "GPT-5.6-Terra", annotations: []},
               %{id: "gpt-5.6-luna", label: "GPT-5.6-Luna", annotations: []},
               %{id: "gpt-5.4", label: "GPT-5.4", annotations: []},
               %{id: "gpt-5.4-mini", label: "GPT-5.4-Mini", annotations: []},
               %{id: "gpt-5.3-codex-spark", label: "GPT-5.3-Codex-Spark", annotations: []}
             ] = ModelAvailability.parse_catalog_output(:codex, output)
    end

    test "codex non-JSON output degrades to an empty list, never raising" do
      assert [] = ModelAvailability.parse_catalog_output(:codex, "error: not logged in\n")
    end
  end

  describe "block/unblock round-trip" do
    test "operator block persists and list_blocks surfaces it" do
      assert :ok =
               ModelAvailability.block_model("cursor", "claude-opus-4-8-thinking-high",
                 until: DateTime.utc_now() |> DateTime.shift(second: @future_block_seconds) |> DateTime.to_iso8601(),
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
      past = DateTime.utc_now() |> DateTime.shift(minute: -1) |> DateTime.to_iso8601()

      assert :ok =
               ModelAvailability.block_model("cursor", "composer-2.5", until: past, reason: "expired test")

      assert ModelAvailability.available?(:cursor, "composer-2.5")
      refute ModelAvailability.blocked_until(:cursor, "composer-2.5")
    end
  end

  describe "list_available_models/2" do
    test "returns available when a model is selected into the static subset" do
      seed_static_catalog(:cursor, [
        %{id: "composer-2.5", label: "Composer", annotations: []}
      ])

      assert {:ok,
              %{
                catalog_status: "available",
                catalog_unavailable: false,
                models: [%{id: "composer-2.5", label: "Composer"}]
              }} = ModelAvailability.list_available_models("cursor")
    end

    test "returns probed_none_selected when the probe cache has models but nothing is selected" do
      seed_probe_cache(:cursor, [
        %{id: "composer-probed", label: "Probed", annotations: []},
        %{id: "composer-next", label: "Next", annotations: []}
      ])

      assert {:ok,
              %{
                catalog_status: "probed_none_selected",
                catalog_unavailable: true,
                models: [],
                universe_count: 2
              }} = ModelAvailability.list_available_models("cursor")
    end

    test "returns unavailable when the agent has no builtin, static, or probe cache" do
      install_catalog_probe(fn _agent, _executables -> {:error, :catalog_unavailable} end)

      assert {:ok,
              %{
                catalog_status: "unavailable",
                catalog_unavailable: true,
                models: []
              }} = ModelAvailability.list_available_models("antigravity")
    end
  end

  describe "list_available/1" do
    test "resolves selected before builtin catalogs" do
      install_catalog_probe(fn
        :codex, _executables -> {:ok, [%{id: "gpt-probed", label: "Probed", annotations: []}]}
        _agent, _executables -> {:error, :catalog_unavailable}
      end)

      seed_static_catalog(:codex, [
        %{id: "gpt-operator", label: "Operator", annotations: []}
      ])

      assert {:ok, [%{id: "gpt-operator"}]} = ModelAvailability.catalog(:codex)

      SettingsStore.put(:model_catalog_static, %{})
      SettingsStore.put(:model_catalogs, %{})
      Application.put_env(:harness, :model_catalog_probe, fn _agent, _executables -> {:error, :catalog_unavailable} end)

      assert {:ok, codex_models} = ModelAvailability.catalog(:codex)
      assert "gpt-5.5" in Enum.map(codex_models, & &1.id)

      assert {:ok, claude_models} = ModelAvailability.catalog(:claude)
      assert "claude-opus-4-8" in Enum.map(claude_models, & &1.id)
    end

    test "round-trips selected membership separately from the probed universe" do
      seed_static_catalog(:cursor, [
        %{id: "composer-selected", label: "Selected", annotations: []}
      ])

      install_catalog_probe(fn
        :cursor, _executables ->
          {:ok,
           [
             %{id: "composer-probed", label: "Probed", annotations: []},
             %{id: "composer-next", label: "Next", annotations: []}
           ]}

        _agent, _executables ->
          {:error, :catalog_unavailable}
      end)

      assert {:ok, %{models: refreshed}} = ModelAvailability.refresh_catalog("cursor")
      assert Enum.map(refreshed, & &1.id) == ["composer-selected"]

      assert {:ok, selected} = ModelAvailability.catalog(:cursor)
      assert Enum.map(selected, & &1.id) == ["composer-selected"]

      assert {:ok, universe} = ModelAvailability.catalog_universe(:cursor)
      assert selected_state(universe, "composer-selected")
      refute selected_state(universe, "composer-probed")

      assert :ok = ModelAvailability.toggle_catalog_model("cursor", "composer-probed")
      assert {:ok, selected} = ModelAvailability.catalog(:cursor)
      assert Enum.map(selected, & &1.id) == ["composer-selected", "composer-probed"]

      assert {:ok, %{models: refreshed}} = ModelAvailability.refresh_catalog("cursor")
      assert Enum.map(refreshed, & &1.id) == ["composer-selected", "composer-probed"]

      assert {:ok, universe} = ModelAvailability.catalog_universe(:cursor)
      assert selected_state(universe, "composer-probed")
      refute selected_state(universe, "composer-next")

      assert :ok = ModelAvailability.toggle_catalog_model("cursor", "composer-probed")
      assert {:ok, selected} = ModelAvailability.catalog(:cursor)
      assert Enum.map(selected, & &1.id) == ["composer-selected"]
    end

    test "omits blocked ids from the catalog" do
      install_catalog_probe()

      seed_static_catalog(:cursor, [
        %{id: "composer-2.5", label: "Composer", annotations: []},
        %{id: "claude-opus-4-8-thinking-high", label: "Opus", annotations: []}
      ])

      assert :ok = ModelAvailability.block_model("cursor", "claude-opus-4-8-thinking-high", reason: "blocked")

      assert [%{id: "composer-2.5"}] = ModelAvailability.list_available(:cursor)
    end

    test "returns catalog_unavailable for agents without a static list when probe fails" do
      install_catalog_probe(fn _agent, _executables -> {:error, :catalog_unavailable} end)
      assert {:error, :catalog_unavailable} = ModelAvailability.list_available(:antigravity)
    end

    test "returns probed antigravity catalog entries when the agy models probe succeeds" do
      install_catalog_probe(fn
        :antigravity, _executables ->
          {:ok,
           [
             %{id: "gemini-3.5-flash", label: "Gemini 3.5 Flash (Medium)", annotations: []},
             %{id: "claude-opus-4-5", label: "Claude Opus 4.6 (Thinking)", annotations: []}
           ]}

        _agent, _executables ->
          {:error, :catalog_unavailable}
      end)

      seed_static_catalog(:antigravity, [
        %{id: "gemini-3.5-flash", label: "Gemini 3.5 Flash (Medium)", annotations: []}
      ])

      assert [%{id: "gemini-3.5-flash"}] = ModelAvailability.list_available(:antigravity)
    end
  end

  describe "dispatch gate" do
    test "allows a pinned model absent from the advisory catalog" do
      parent = self()
      install_catalog_probe()

      project = ProjectFixture.from_repo(@sample, name: "advisory-model-gate", roadmap_path: @sample)
      assert :ok = ProjectRegistry.register(project)

      seed_static_catalog(:cursor, [
        %{id: "composer-2.5", label: "Composer", annotations: []}
      ])

      assert :ok = Config.put({:agent_model, :cursor}, "gpt-unlisted", "test")

      Application.put_env(:harness, :oban_insert, fn changeset ->
        send(parent, :oban_insert_called)
        {:ok, Ecto.Changeset.apply_action!(changeset, :insert)}
      end)

      assert {:ok, _job} = Dispatch.task(project.name, "2", "cursor")
      assert_receive :oban_insert_called
    end

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

  defp install_catalog_probe(fun \\ nil)

  defp install_catalog_probe(nil) do
    install_catalog_probe(fn agent, _executables ->
      case SettingsStore.fetch(:model_catalog_static) do
        {:ok, %{^agent => models}} when is_list(models) and models != [] -> {:ok, models}
        _ -> {:error, :catalog_unavailable}
      end
    end)
  end

  defp install_catalog_probe(fun), do: Application.put_env(:harness, :model_catalog_probe, fun)

  defp seed_static_catalog(agent, models) do
    current =
      case SettingsStore.fetch(:model_catalog_static) do
        {:ok, map} when is_map(map) -> map
        _ -> %{}
      end

    SettingsStore.put(:model_catalog_static, Map.put(current, agent, models))
  end

  defp seed_probe_cache(agent, models) do
    current =
      case SettingsStore.fetch(:model_catalogs) do
        {:ok, map} when is_map(map) -> map
        _ -> %{}
      end

    entry = %{fetched_at: DateTime.utc_now(), models: models}

    SettingsStore.put(:model_catalogs, Map.put(current, agent, entry))
  end

  defp selected_state(universe, id) do
    universe
    |> Enum.find(&(&1.id == id))
    |> Map.fetch!(:selected?)
  end

  defp restore_env(key, nil), do: Application.delete_env(:harness, key)
  defp restore_env(key, value), do: Application.put_env(:harness, key, value)
end
