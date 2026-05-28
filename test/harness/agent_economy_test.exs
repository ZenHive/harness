defmodule Harness.AgentEconomyTest do
  @moduledoc """
  Enforces the descripex annotation contract on the driver-surface modules
  exposed via `Harness.Manifest`.

  Without enforcement, `:hints` metadata rots as the surface evolves — a new
  public function or a renamed param can ship un-annotated, and the chat
  orchestrator's tool list silently drifts from reality. This suite catches
  both at build time.
  """

  use ExUnit.Case, async: true

  describe "annotated modules carry :hints on every visible public function" do
    for module <- Harness.Manifest.modules() do
      @module module

      test "#{inspect(module)}: every non-hidden function has :hints metadata" do
        Code.ensure_loaded!(@module)

        function_entries =
          case Code.fetch_docs(@module) do
            {:docs_v1, _, _, _, _, _, docs} ->
              Enum.filter(docs, fn
                {{:function, _, _}, _, _, _, _} -> true
                _ -> false
              end)

            other ->
              flunk("Code.fetch_docs/1 did not return a docs_v1 chunk for #{inspect(@module)}: #{inspect(other)}")
          end

        # Functions that opt out via @doc false (doc == :hidden) are not part of
        # the consumer-facing surface — skip them. The remaining functions are
        # what an external AI consumer will see; each MUST carry hints.
        missing =
          function_entries
          |> Enum.reject(fn {_id, _ann, _sig, doc, _meta} -> doc == :hidden end)
          |> Enum.reject(fn {{:function, name, arity}, _ann, _sig, _doc, meta} ->
            Map.has_key?(meta, :hints) and
              describes_function?(meta[:hints], name, arity)
          end)
          |> Enum.map(fn {{:function, name, arity}, _, _, _, _} -> "#{name}/#{arity}" end)

        assert missing == [],
               "#{inspect(@module)} has non-hidden public functions without :hints — add an api() declaration or @doc false: #{Enum.join(missing, ", ")}"
      end
    end

    # Hints presence is necessary but not sufficient — an empty map would
    # technically satisfy Map.has_key?. Require a non-empty :description so
    # the manifest at least carries the human-readable purpose of the call.
    defp describes_function?(hints, _name, _arity) when is_map(hints) do
      case Map.get(hints, :description) do
        desc when is_binary(desc) and byte_size(desc) > 0 -> true
        _ -> false
      end
    end

    defp describes_function?(_hints, _name, _arity), do: false
  end

  describe "Harness.Manifest.build/0" do
    test "covers every curated driver-surface module" do
      manifest = Harness.Manifest.build()
      module_names = Enum.map(manifest.modules, & &1.module)

      for module <- Harness.Manifest.modules() do
        assert inspect(module) in module_names,
               "Harness.Manifest.build/0 dropped #{inspect(module)}"
      end

      assert manifest.version == "1.0"
      assert is_binary(manifest.generated_at)
    end

    test "each annotated module exposes __api__/0 with at least one entry" do
      for module <- Harness.Manifest.modules() do
        Code.ensure_loaded!(module)

        assert function_exported?(module, :__api__, 0),
               "#{inspect(module)} missing __api__/0 — likely missing `use Descripex` at module top"

        api_entries = module.__api__()

        assert api_entries != [],
               "#{inspect(module)} has __api__/0 but no api() declarations — annotate at least one public function"
      end
    end
  end

  describe "Harness.Manifest.mcp_tools/1" do
    test "renders a valid MCP tool definition per api()-annotated function" do
      tools = Harness.Manifest.mcp_tools()

      assert is_list(tools)
      assert tools != []

      for tool <- tools do
        assert is_binary(tool.name) and tool.name != ""
        assert is_binary(tool.description) and tool.description != ""
        assert is_map(tool.inputSchema)
        assert tool.inputSchema.type == "object"
        assert is_map(tool.inputSchema.properties)
        assert is_list(tool.inputSchema.required)
      end
    end

    test "names are unique across the curated surface" do
      names = Enum.map(Harness.Manifest.mcp_tools(), & &1.name)
      assert names == Enum.uniq(names), "MCP tool names must be unique across the manifest"
    end

    test "exchange_data params declare a source hint" do
      # Cross-checks the structured hints: any param marked :exchange_data
      # MUST carry a `source:` hint pointing to the upstream lookup tool
      # (e.g. start_run's :project sourced from ProjectRegistry.lookup/1).
      # Without :source, the chat orchestrator can't decide which tool to
      # invoke first to obtain the value.
      missing =
        for module <- Harness.Manifest.modules(),
            entry <- module.__api__(),
            {param_name, details} <- Map.get(entry.hints, :params, %{}) || %{},
            details[:kind] == :exchange_data,
            is_nil(details[:source]) do
          "#{inspect(module)}.#{entry.name}/#{entry.arity} param :#{param_name} (kind: :exchange_data, source: missing)"
        end

      assert missing == [],
             "exchange_data params must declare source: hints. Missing in: #{Enum.join(missing, ", ")}"
    end
  end
end
