defmodule Harness.Chat.Tools do
  @moduledoc """
  Tool registry and dispatch for chat sessions.

  Built from `Harness.Manifest` at session startup — each MCP tool name maps to
  an MFA plus its JSON Schema. Dispatch validates arguments before `apply/3`.

  ## MCP / JSON param boundary

  Descripex 0.8+ emits typed JSON Schema from `@spec` where possible; **this
  module is the consumer-side coercion layer** that maps JSON arguments onto
  Elixir `apply/3` heads:

  - Omitted or JSON-`null` optional params become `:__omit__` and are dropped from
    the trailing arity so the function's `\\ default` head runs (not the static
    `api()` schema default, which may be a sentinel like `:configured_result_store`
    or `nil` that would hit a disabled guard).
  - Interior `:__omit__` gaps before explicit later args are filled from the
    declared schema `default` (positional-default semantics).
  - Atom-typed params (schema `"type": "string"` with an `atom` description
    hint from descripex) accept plain JSON strings (`"codex"`) as well as
    `":codex"`.
  - Boolean and keyword-list params keep the existing targeted coercions.

  Params a JSON client cannot construct (`%Struct{}`, `module()`, module lists)
  are filtered off the MCP surface in `Harness.Manifest.mcp_tools/1`, not patched
  per function here.
  """

  alias Harness.Chat.Schema

  @dispatch_exceptions [
    ArgumentError,
    BadArityError,
    BadFunctionError,
    CaseClauseError,
    ErlangError,
    FunctionClauseError,
    KeyError,
    MatchError,
    Protocol.UndefinedError,
    RuntimeError,
    UndefinedFunctionError,
    WithClauseError
  ]

  @typedoc "Resolved tool entry keyed by MCP tool name."
  @type entry :: %{
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:module) => module(),
          required(:function) => atom(),
          required(:arity) => non_neg_integer(),
          required(:defaults) => non_neg_integer(),
          required(:input_schema) => map(),
          required(:param_keys) => [atom()],
          required(:params) => map()
        }

  @type registry :: %{String.t() => entry()}

  @doc "Builds a tool registry from the curated driver surface."
  @spec build(keyword()) :: registry()
  def build(opts \\ []) do
    modules = Keyword.get(opts, :modules, Harness.Manifest.modules())

    opts
    |> Keyword.take([:name_style])
    |> Harness.Manifest.mcp_tools()
    |> Map.new(fn tool ->
      entry = Harness.Manifest.resolve_tool!(tool, modules)
      {tool.name, entry}
    end)
  end

  @doc "Returns MCP tool definitions suitable for backend requests."
  @spec schemas(registry()) :: [map()]
  def schemas(registry) when is_map(registry) do
    Enum.map(registry, fn {_name, entry} ->
      %{
        name: entry.name,
        description: entry.description,
        input_schema: entry.input_schema
      }
    end)
  end

  @doc "Dispatches `tool_name` with JSON `arguments` via apply/3 after schema validation."
  @spec dispatch(registry(), String.t(), map()) ::
          {:ok, term()}
          | {:error, {:unknown_tool, String.t()}}
          | {:error, {:schema_validation_failed, [map()]}}
          | {:error, {:dispatch_failed, String.t()}}
  def dispatch(registry, tool_name, arguments) when is_map(registry) and is_binary(tool_name) and is_map(arguments) do
    with {:ok, entry} <- lookup(registry, tool_name),
         {:ok, arguments} <- coerce_args(entry, arguments),
         :ok <- validate_args(entry, arguments),
         {:ok, args} <- build_apply_args(entry, arguments) do
      safe_apply(entry, args)
    end
  end

  @spec lookup(registry(), String.t()) :: {:ok, entry()} | {:error, {:unknown_tool, String.t()}}
  defp lookup(registry, tool_name) do
    case Map.fetch(registry, tool_name) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, {:unknown_tool, tool_name}}
    end
  end

  # Wrap `Schema.validate/2`'s generic `{:error, [violations]}` into the
  # `{:schema_validation_failed, ...}` shape every downstream surface (chat
  # backend + MCP server) pattern-matches.
  @spec validate_args(entry(), map()) ::
          :ok | {:error, {:schema_validation_failed, [Schema.error()]}}
  defp validate_args(entry, arguments) do
    case Schema.validate(arguments, entry.input_schema) do
      :ok -> :ok
      {:error, violations} -> {:error, {:schema_validation_failed, violations}}
    end
  end

  @spec coerce_args(entry(), map()) :: {:ok, map()}
  defp coerce_args(entry, arguments) do
    {:ok, Map.new(arguments, fn {key, value} -> {key, coerce_arg(entry, key, value)} end)}
  end

  @spec coerce_arg(entry(), term(), term()) :: term()
  defp coerce_arg(entry, key, value) do
    details = param_details(entry, key)

    if boolean_param?(details) do
      coerce_boolean(value)
    else
      value
    end
  end

  @spec param_details(entry(), term()) :: map()
  defp param_details(%{params: params}, key) do
    key_string = to_string(key)

    Enum.find_value(params, %{}, fn {param_key, details} ->
      if Atom.to_string(param_key) == key_string, do: details
    end)
  end

  @spec atom_param?(map()) :: boolean()
  defp atom_param?(details) when is_map(details) do
    schema = Map.get(details, :schema, %{})
    schema_type = if is_map(schema), do: Map.get(schema, "type", Map.get(schema, :type))
    desc = Map.get(details, :description, "")

    schema_type in ["string", :string] and Regex.match?(~r/\batom\b/i, desc)
  end

  @spec boolean_param?(map()) :: boolean()
  defp boolean_param?(details) when is_map(details) do
    schema = Map.get(details, :schema, %{})
    schema_type = if is_map(schema), do: Map.get(schema, "type", Map.get(schema, :type))

    schema_type in ["boolean", :boolean] or is_boolean(Map.get(details, :default))
  end

  @spec coerce_boolean(term()) :: term()
  defp coerce_boolean(value) when is_boolean(value), do: value

  defp coerce_boolean(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      "false" -> false
      _other -> value
    end
  end

  defp coerce_boolean(%{"value" => value}), do: coerce_boolean(value)
  defp coerce_boolean(%{value: value}), do: coerce_boolean(value)
  defp coerce_boolean(value), do: value

  @spec build_apply_args(entry(), map()) :: {:ok, [term()]} | {:error, {:schema_validation_failed, [map()]}}
  defp build_apply_args(entry, arguments) do
    args = Enum.map(entry.param_keys, &resolve_param(entry, &1, arguments))

    if Enum.any?(args, &(&1 == :__missing__)) do
      {:error, {:schema_validation_failed, [%{path: "#", message: "missing required arguments for #{entry.name}"}]}}
    else
      {:ok, finalize_apply_args(args, entry)}
    end
  end

  # Drops trailing `:__omit__` markers so `apply/3` selects a lower-arity head
  # with Elixir runtime defaults. Fills interior `:__omit__` gaps (optional
  # params before explicit later args) from the declared schema default.
  @spec finalize_apply_args([term()], entry()) :: [term()]
  defp finalize_apply_args(args, %{params: params, param_keys: keys}) do
    trailing_omit_count =
      Enum.reduce_while(Enum.reverse(args), 0, fn
        :__omit__, n -> {:cont, n + 1}
        _, n -> {:halt, n}
      end)

    keep_count = length(args) - trailing_omit_count

    keys
    |> Enum.zip(args)
    |> Enum.take(keep_count)
    |> Enum.map(fn {key, value} ->
      if value == :__omit__ do
        Map.get(params[key] || %{}, :default, :__omit__)
      else
        value
      end
    end)
  end

  @spec resolve_param(entry(), atom(), map()) :: term()
  defp resolve_param(%{params: params}, key, arguments) do
    key_str = Atom.to_string(key)
    details = Map.get(params, key, %{})
    present? = Map.has_key?(arguments, key_str) or Map.has_key?(arguments, key)

    case Map.get(arguments, key_str, Map.get(arguments, key)) do
      nil ->
        case details do
          %{default: _} -> :__omit__
          _ when present? -> nil
          _ -> :__missing__
        end

      value ->
        decode_param(value, details)
    end
  end

  @spec keyword_list_param?(map()) :: boolean()
  defp keyword_list_param?(details) do
    is_list(Map.get(details, :default)) or
      String.starts_with?(Map.get(details, :description) || "", "Keyword list")
  end

  @spec decode_param(term(), map()) :: term()
  # A keyword-list param (signalled by a list default or its declared description)
  # arrives from JSON as an object/map. Decode it to a keyword list so the target
  # function's `Keyword.get/3` does not crash with "no function clause matching".
  # Top-level keys are atomized (only known atoms; unknowns dropped for forward
  # compat, same contract as ResultStore.Postgres.apply_filters for filters).
  # This clause must precede the generic map clause.
  defp decode_param(value, %{kind: :value} = details) when is_map(value) do
    if keyword_list_param?(details), do: to_atom_kwlist(value), else: atomize_keys(value)
  end

  # The same object/keyword param can also arrive JSON-encoded as a *string*
  # rather than a JSON object. descripex's `kind: :value` emits a typeless
  # schema property (description only, no `"type"`), so an MCP client with no
  # type hint serializes a structured argument as JSON text — e.g. filters as
  # `"{\"agent\": \"cursor\"}"`. Parse it, then decode like the map clause; a
  # non-JSON / non-collection string falls through to the plain-binary clause.
  # Detection must not require a list default: mark_* `opts` are required
  # (no schema default) but are still keyword lists.
  defp decode_param(value, %{kind: :value} = details) when is_binary(value) do
    cond do
      keyword_list_param?(details) ->
        decode_keyword_list_string(value)

      String.starts_with?(value, ":") ->
        value |> String.slice(1..-1//1) |> String.to_existing_atom()

      atom_param?(details) ->
        case safe_to_existing_atom(value) do
          {:ok, atom} -> atom
          :error -> value
        end

      true ->
        value
    end
  rescue
    ArgumentError -> value
  end

  defp decode_param(value, _details), do: value

  @spec decode_keyword_list_string(String.t()) :: term()
  defp decode_keyword_list_string(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> to_atom_kwlist(decoded)
      {:ok, decoded} when is_list(decoded) -> decoded
      _other -> value
    end
  end

  @spec safe_apply(entry(), [term()]) :: {:ok, term()} | {:error, term()}
  defp safe_apply(%{module: module, function: function}, args) do
    {:ok, apply(module, function, args)}
  rescue
    error in @dispatch_exceptions -> {:error, {:dispatch_failed, Exception.message(error)}}
  end

  @spec atomize_keys(map()) :: map()
  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      atom_key =
        key
        |> to_string()
        |> String.to_existing_atom()

      {atom_key, atomize_value(value)}
    end)
  rescue
    ArgumentError ->
      map
  end

  @spec atomize_value(term()) :: term()
  defp atomize_value(value) when is_map(value), do: atomize_keys(value)
  defp atomize_value(value) when is_list(value), do: Enum.map(value, &atomize_value/1)
  defp atomize_value(value), do: value

  @spec to_atom_kwlist(map()) :: keyword()
  # Per-key tolerant atomization for keyword-list params from JSON (e.g. filters).
  # Only keys that are existing atoms become atom keys in the kwlist; unknown
  # keys are dropped (ignored) for forward compat — same contract as
  # ResultStore.Postgres.apply_filters on list_run_records filters.
  defp to_atom_kwlist(map) when is_map(map) do
    Enum.flat_map(map, fn {key, value} ->
      case safe_to_existing_atom(key) do
        {:ok, atom_key} -> [{atom_key, atomize_value(value)}]
        :error -> []
      end
    end)
  end

  @spec safe_to_existing_atom(term()) :: {:ok, atom()} | :error
  defp safe_to_existing_atom(key) do
    atom = key |> to_string() |> String.to_existing_atom()
    {:ok, atom}
  rescue
    ArgumentError -> :error
  end
end
