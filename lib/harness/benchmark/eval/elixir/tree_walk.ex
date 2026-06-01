defmodule Harness.Benchmark.Eval.Elixir.TreeWalk do
  @moduledoc false

  @type tree_node :: %{required(:value) => term(), optional(:children) => [tree_node()]}

  @doc false
  @spec walk(nil | tree_node() | [tree_node()]) :: [term()]
  def walk(nil), do: []

  def walk(%{value: value, children: children}) when is_list(children) do
    [value | Enum.flat_map(children, &walk/1)]
  end

  def walk(%{value: value}), do: [value]
end
