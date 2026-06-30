defmodule Harness.ToolingBaseline.MixProjectReader do
  @moduledoc false

  @doc "Reads declared dep and alias names from a committed mix.exs."
  @spec read(String.t()) :: {:ok, %{deps: MapSet.t(atom()), aliases: MapSet.t(atom())}} | {:error, term()}
  def read(path) when is_binary(path) do
    with {:ok, content} <- File.read(path),
         {:ok, ast} <- Code.string_to_quoted(content) do
      {:ok, %{deps: extract_deps(ast), aliases: extract_aliases(ast)}}
    end
  end

  @spec extract_deps(Macro.t()) :: MapSet.t(atom())
  defp extract_deps(ast) do
    {_ast, deps} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:def, _, [{:deps, _, _}, [do: body]]} = node, acc ->
          {node, MapSet.union(acc, names_from_dep_list(body))}

        {:defp, _, [{:deps, _, _}, [do: body]]} = node, acc ->
          {node, MapSet.union(acc, names_from_dep_list(body))}

        {{:., _, [{:__aliases__, _, [:Mix]}, :install]}, _, [body]} = node, acc ->
          {node, MapSet.union(acc, names_from_dep_list(body))}

        node, acc ->
          {node, acc}
      end)

    deps
  end

  @spec extract_aliases(Macro.t()) :: MapSet.t(atom())
  defp extract_aliases(ast) do
    {_ast, aliases} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:def, _, [{:aliases, _, _}, [do: body]]} = node, acc ->
          {node, MapSet.union(acc, names_from_alias_list(body))}

        {:defp, _, [{:aliases, _, _}, [do: body]]} = node, acc ->
          {node, MapSet.union(acc, names_from_alias_list(body))}

        node, acc ->
          {node, acc}
      end)

    aliases
  end

  @spec names_from_dep_list(term()) :: MapSet.t(atom())
  defp names_from_dep_list({:__block__, _, items}), do: names_from_dep_list(items)

  defp names_from_dep_list(list) when is_list(list),
    do: list |> Enum.map(&dep_name/1) |> Enum.reject(&is_nil/1) |> MapSet.new()

  defp names_from_dep_list(other), do: names_from_dep_list(List.wrap(other))

  @spec names_from_alias_list(term()) :: MapSet.t(atom())
  defp names_from_alias_list({:__block__, _, items}), do: names_from_alias_list(items)

  defp names_from_alias_list(list) when is_list(list),
    do: list |> Enum.map(&alias_name/1) |> Enum.reject(&is_nil/1) |> MapSet.new()

  defp names_from_alias_list(other), do: names_from_alias_list(List.wrap(other))

  @spec dep_name(term()) :: atom() | nil
  defp dep_name({:{}, _, [name | _]}) when is_atom(name), do: name
  defp dep_name({name, _second}) when is_atom(name), do: name
  defp dep_name({name, _, _} = tuple) when is_atom(name) and is_tuple(tuple), do: name
  defp dep_name(name) when is_atom(name), do: name
  defp dep_name(_other), do: nil

  @spec alias_name(term()) :: atom() | nil
  defp alias_name({name, _tasks}) when is_atom(name), do: name
  defp alias_name(name) when is_atom(name), do: name
  defp alias_name(_other), do: nil
end
