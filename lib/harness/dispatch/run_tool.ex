defmodule Harness.Dispatch.RunTool do
  @moduledoc """
  Compile-time DSL that generates the flat, JSON-native run-observation tools on
  `Harness.Dispatch` (`status` / `transcript` / `transcript_events`).

  ## Why this exists

  Each generated tool wraps an excluded `Harness.Run` observation function.
  Those take a `run :: String.t() | pid()` handle, so descripex marks the param
  `:exchange_data` and `Harness.Manifest.mcp_tools/1` drops them from the MCP /
  chat surface — even though the **run-id-string path is perfectly
  JSON-driveable**. The `pid` alternative is the only thing making them "exchange
  data". A JSON orchestrator that called `dispatch-task` and holds a `run_id`
  therefore had no JSON tool to follow that live run. `defrun_tool/1` closes the
  gap: it emits a one-arg `run_id` (`:value`) wrapper that delegates to
  `Harness.Run.<name>/1`, projects the `{:ok, value}` payload through a
  summarizer into a JSON-safe map, and passes `{:error, :not_found}` through
  verbatim.

  ## Scope — uniform delegates only

  Only the `{:ok, _} | {:error, :not_found}` family is macro-generated. The
  shapes that diverge stay hand-written on `Harness.Dispatch`:

    * `cancel/1` returns a bare `:ok` (idempotent), not `{:ok, _}`.
    * Routing tools (`recommend/2`, `assess_facets/1`) take facet/domain opts,
      not a `run_id` — they use `defopts_tool/1` instead.

  This is the documented Elixir lesson — "when shapes genuinely diverge, split
  macros, don't grow a single one" (see `development-philosophy.md`, the Ecto
  field-macro precedent).

  ## Contract

  The using module MUST `use Descripex` (the macro emits a `Descripex.api/3`
  declaration) and define the named summarizer as a function in scope. The
  `NimbleOptions` schema below is the macro's public contract: adding a knob
  means editing the schema, which surfaces drift at review.

  ## Usage

      defrun_tool name: :status,
        summarize: :summarize_status,
        description: "Snapshot one in-flight or lingering-terminal run by run_id.",
        run_id_doc: "Run id string from dispatch-task / dispatch-await.",
        returns: "{:ok, map} | {:error, :not_found}"

  Expands to a `Descripex.api/3` declaration, an `@spec`, and a `def` delegating
  to `Harness.Run.<name>/1`, projecting `{:ok, value}` through the named
  summarizer and passing `{:error, :not_found}` through verbatim.
  """

  @opts_schema NimbleOptions.new!(
                 name: [
                   type: :atom,
                   required: true,
                   doc: "Generated function name on the using module and MCP suffix (`dispatch-<name>`)."
                 ],
                 description: [
                   type: :string,
                   required: true,
                   doc: "Tool description rendered into the descripex `api/3` declaration."
                 ],
                 returns: [
                   type: :string,
                   required: true,
                   doc: "The `returns` description in the `api/3` declaration."
                 ],
                 opts_doc: [
                   type: :string,
                   required: true,
                   doc: "The optional `opts` keyword-list parameter description."
                 ]
               )

  @schema NimbleOptions.new!(
            name: [
              type: :atom,
              required: true,
              doc:
                "The generated function name on the using module. Also the `Harness.Run` function it delegates to (same atom) and the MCP tool suffix (`dispatch-<name>`)."
            ],
            summarize: [
              type: :atom,
              required: true,
              doc:
                "Name of a 1-arity function in the using module that maps the delegate's `{:ok, value}` payload to a JSON-safe map."
            ],
            description: [
              type: :string,
              required: true,
              doc: "The tool description rendered into the descripex `api/3` declaration."
            ],
            run_id_doc: [
              type: :string,
              required: true,
              doc: "The `run_id` parameter description in the `api/3` declaration."
            ],
            returns: [
              type: :string,
              required: true,
              doc: "The `returns` description in the `api/3` declaration."
            ]
          )

  @doc """
  Generates one flat, JSON-native opts-only tool on the using module.

  For routing and refresh surfaces whose sole JSON-passable input is an optional
  keyword list (`assess_facets/1`), not a `run_id`.
  """
  @spec defopts_tool(keyword()) :: Macro.t()
  defmacro defopts_tool(opts) do
    opts = NimbleOptions.validate!(opts, @opts_schema)
    name = Keyword.fetch!(opts, :name)
    description = Keyword.fetch!(opts, :description)
    returns = Keyword.fetch!(opts, :returns)
    opts_doc = Keyword.fetch!(opts, :opts_doc)

    quote do
      Descripex.api(unquote(name), unquote(description),
        params: [
          opts: [kind: :value, default: [], description: unquote(opts_doc)]
        ],
        returns: %{type: :tuple, description: unquote(returns)}
      )
    end
  end

  @doc """
  Generates one flat, JSON-native run-observation tool on the using module.

  Expands a `defrun_tool name: :status, summarize: :summarize_status, ...`
  declaration (validated against the `NimbleOptions` schema) into a
  `Descripex.api/3` declaration, an `@spec`, and a one-arg `run_id` `def` that
  delegates to `Harness.Run.<name>/1`, projecting `{:ok, value}` through the
  named summarizer and passing `{:error, :not_found}` through verbatim. See the
  module doc for the full declaration shape and rationale.
  """
  @spec defrun_tool(keyword()) :: Macro.t()
  defmacro defrun_tool(opts) do
    opts = NimbleOptions.validate!(opts, @schema)
    name = Keyword.fetch!(opts, :name)
    summarize = Keyword.fetch!(opts, :summarize)
    description = Keyword.fetch!(opts, :description)
    run_id_doc = Keyword.fetch!(opts, :run_id_doc)
    returns = Keyword.fetch!(opts, :returns)

    quote do
      Descripex.api(unquote(name), unquote(description),
        params: [run_id: [kind: :value, description: unquote(run_id_doc)]],
        returns: %{type: :tuple, description: unquote(returns)}
      )

      @spec unquote(name)(String.t()) :: {:ok, map()} | {:error, :not_found}
      def unquote(name)(run_id) when is_binary(run_id) do
        case Harness.Run.unquote(name)(run_id) do
          {:ok, value} -> {:ok, unquote(summarize)(value)}
          {:error, :not_found} = error -> error
        end
      end
    end
  end
end
