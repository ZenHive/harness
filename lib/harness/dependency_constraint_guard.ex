defmodule Harness.DependencyConstraintGuard do
  @moduledoc """
  Flags over-tight three-part optimistic dependency constraints in `mix.exs`.
  """

  @three_part_optimistic ~r/~>\s+\d+\.\d+\.\d+/

  @type violation :: %{
          line: pos_integer(),
          text: String.t(),
          constraint: String.t()
        }

  @doc "Returns unjustified three-part `~> x.y.z` constraints in `content`."
  @spec violations_in(String.t()) :: [violation()]
  def violations_in(content) when is_binary(content) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(&line_violation/1)
  end

  @doc "Reads `path` and returns unjustified three-part `~> x.y.z` constraints."
  @spec violations(String.t()) :: {:ok, [violation()]} | {:error, File.posix()}
  def violations(path) when is_binary(path) do
    with {:ok, content} <- File.read(path) do
      {:ok, violations_in(content)}
    end
  end

  @spec line_violation({String.t(), pos_integer()}) :: [violation()]
  defp line_violation({line, line_number}) do
    {code, comment} = split_comment(line)

    if over_tight?(code) and blank_comment?(comment) do
      [%{line: line_number, text: String.trim(line), constraint: constraint(code)}]
    else
      []
    end
  end

  @spec split_comment(String.t()) :: {String.t(), String.t() | nil}
  defp split_comment(line) do
    case String.split(line, "#", parts: 2) do
      [code, comment] -> {code, comment}
      [code] -> {code, nil}
    end
  end

  @spec over_tight?(String.t()) :: boolean()
  defp over_tight?(code), do: Regex.match?(@three_part_optimistic, code)

  @spec blank_comment?(String.t() | nil) :: boolean()
  defp blank_comment?(nil), do: true
  defp blank_comment?(comment), do: String.trim(comment) == ""

  @spec constraint(String.t()) :: String.t()
  defp constraint(code) do
    [match] = Regex.run(@three_part_optimistic, code)
    match
  end
end
