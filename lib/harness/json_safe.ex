defmodule Harness.JSONSafe do
  @moduledoc """
  Recursively rewrites arbitrary terms into JSON-encodable values.

  Two harness surfaces serialize unknown terms before `Jason.encode!/1`: the MCP
  tool-result payload (`Harness.Dashboard.MCPServer`) and the chat tool-result
  encoding (`Harness.Chat.Session`). They share the same backbone — walk maps,
  lists, structs, atoms — but differ at two leaves, so the conversion is
  parameterized rather than forced into one shape:

    * **tuples** — MCP flattens a tuple to a JSON array (`:tuples` = `:list`);
      chat inspects it to a string (`:tuples` = `:inspect`). JSON has no tuple
      type, so both are lossy-but-valid; each surface keeps its prior choice.
    * **`nil` / booleans** — MCP stringifies every atom including `nil`/`true`/
      `false` (`:bare_atoms` = `:stringify`); chat preserves them as JSON
      `null`/`true`/`false` (`:bare_atoms` = `:preserve`). This is chat's one
      deliberate divergence from its hand-rolled helper: the old `to_jsonable/1`
      had a preserve clause that was dead code (shadowed by the atom clause
      above it, since `nil`/`true`/`false` are atoms), so it actually stringified
      them — the preset implements the evident intent instead.
    * **`DateTime`** — chat renders it as an ISO-8601 string before the generic
      struct path (`:datetime_iso8601?` = `true`); MCP has no special case and
      falls through to the struct branch (`false`).

  `mcp_opts/0` and `chat_opts/0` name the two presets so each caller's output
  matches what its hand-rolled helper produced — modulo the chat nil/boolean fix
  above, and that values JSON cannot represent (non-binary bitstrings) are now
  inspected rather than passed through to crash `Jason.encode!/1`.
  """

  @typedoc "How to render a tuple (JSON has no tuple type)."
  @type tuple_mode :: :list | :inspect

  @typedoc "How to render bare atoms other than the recognized leaves."
  @type bare_atom_mode :: :stringify | :preserve

  @typedoc "Conversion options — see module doc."
  @type opts :: [
          tuples: tuple_mode(),
          bare_atoms: bare_atom_mode(),
          datetime_iso8601?: boolean()
        ]

  @mcp_opts [tuples: :list, bare_atoms: :stringify, datetime_iso8601?: false]
  @chat_opts [tuples: :inspect, bare_atoms: :preserve, datetime_iso8601?: true]

  @doc """
  Preset matching `Harness.Dashboard.MCPServer`'s former `json_safe/1`:
  tuples → list, every atom stringified, no `DateTime` special-casing.

  ## Examples

      iex> Harness.JSONSafe.mcp_opts()
      [tuples: :list, bare_atoms: :stringify, datetime_iso8601?: false]
  """
  @spec mcp_opts() :: opts()
  def mcp_opts, do: @mcp_opts

  @doc """
  Preset matching `Harness.Chat.Session`'s former `to_jsonable/1`: tuples
  inspected, `nil`/booleans preserved, `DateTime` rendered ISO-8601.

  ## Examples

      iex> Harness.JSONSafe.chat_opts()
      [tuples: :inspect, bare_atoms: :preserve, datetime_iso8601?: true]
  """
  @spec chat_opts() :: opts()
  def chat_opts, do: @chat_opts

  @doc """
  Converts `term` to a JSON-encodable value under `opts`.

  ## Examples

      iex> Harness.JSONSafe.encode(%{a: 1}, Harness.JSONSafe.chat_opts())
      %{"a" => 1}

      iex> Harness.JSONSafe.encode({:ok, 1}, Harness.JSONSafe.mcp_opts())
      ["ok", 1]
  """
  @spec encode(term(), opts()) :: term()
  def encode(term, opts) when is_list(opts) do
    convert(term, normalize(opts))
  end

  @spec normalize(opts()) :: %{tuples: tuple_mode(), bare_atoms: bare_atom_mode(), datetime_iso8601?: boolean()}
  defp normalize(opts) do
    %{
      tuples: Keyword.get(opts, :tuples, :inspect),
      bare_atoms: Keyword.get(opts, :bare_atoms, :preserve),
      datetime_iso8601?: Keyword.get(opts, :datetime_iso8601?, false)
    }
  end

  @spec convert(term(), map()) :: term()
  defp convert(%DateTime{} = dt, %{datetime_iso8601?: true}), do: DateTime.to_iso8601(dt)
  defp convert(%_struct{} = value, mode), do: value |> Map.from_struct() |> convert(mode)
  defp convert(value, mode) when is_map(value), do: Map.new(value, fn {k, v} -> {key(k), convert(v, mode)} end)
  defp convert(value, mode) when is_list(value), do: Enum.map(value, &convert(&1, mode))
  defp convert(value, %{tuples: :list} = mode) when is_tuple(value), do: value |> Tuple.to_list() |> convert(mode)
  defp convert(value, %{tuples: :inspect}) when is_tuple(value), do: inspect(value)
  defp convert(value, %{bare_atoms: :preserve}) when is_nil(value) or is_boolean(value), do: value
  defp convert(value, _mode) when is_atom(value), do: Atom.to_string(value)

  defp convert(value, _mode) when is_pid(value) or is_reference(value) or is_function(value) or is_port(value),
    do: inspect(value)

  defp convert(value, _mode) when is_binary(value) or is_number(value), do: value
  defp convert(value, _mode), do: inspect(value)

  @spec key(term()) :: String.t()
  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k) when is_binary(k), do: k
  defp key(k), do: inspect(k)
end
