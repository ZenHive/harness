defmodule Harness.Roadmap.TaskIdRewriter do
  @moduledoc """
  Reassigns stale-branch roadmap task ids before a landing push.

  `rmap new` allocates numeric ids from the task file it sees in an isolated
  run worktree. If two runs file tasks concurrently from the same base, both can
  create `id = "200"` locally. At land time the second branch has been rebased
  onto a target where `200` already names another task, so the newly-added block
  must get the next free id before the roadmap is pushed.
  """

  @type rewrite :: %{from: String.t(), to: String.t()}
  @type result :: :unchanged | {:rewritten, String.t(), [rewrite()]}

  @id_line_regex ~r/^(\s*id\s*=\s*)("?)(\d+)\2\s*$/m

  @doc """
  Rewrites new task blocks in `head_toml` whose ids collide with `base_toml`.
  """
  @spec rewrite_collisions(String.t(), String.t()) :: result()
  def rewrite_collisions(base_toml, head_toml) when is_binary(base_toml) and is_binary(head_toml) do
    base_blocks = task_blocks(base_toml)
    head_blocks = task_blocks(head_toml)
    base_by_id = Map.new(base_blocks, &{&1.id, &1.body})
    used_ids = used_ids(base_blocks ++ head_blocks)

    {rewritten, rewrites, _used} =
      Enum.reduce(head_blocks, {head_toml, [], used_ids}, fn block, {text, acc, used} ->
        if colliding_new_block?(block, base_by_id) do
          next = next_id(used)
          updated = rewrite_block_id(block.body, next)
          {String.replace(text, block.body, updated, global: false), [%{from: block.id, to: next} | acc], [next | used]}
        else
          {text, acc, used}
        end
      end)

    case Enum.reverse(rewrites) do
      [] -> :unchanged
      changed -> {:rewritten, rewritten, changed}
    end
  end

  @spec colliding_new_block?(map(), map()) :: boolean()
  defp colliding_new_block?(%{id: id, body: body}, base_by_id) do
    case Map.fetch(base_by_id, id) do
      {:ok, ^body} -> false
      {:ok, _other} -> true
      :error -> false
    end
  end

  @spec task_blocks(String.t()) :: [map()]
  defp task_blocks(toml) do
    ~r/(^|\n)\[\[task\]\].*?(?=\n\[\[task\]\]|\z)/s
    |> Regex.scan(toml)
    |> Enum.flat_map(&block_with_id(List.first(&1)))
  end

  @spec block_with_id(String.t()) :: [map()]
  defp block_with_id(block) do
    case Regex.run(@id_line_regex, block, capture: :all_but_first) do
      [_prefix, _quote, id] -> [%{id: id, body: block}]
      _other -> []
    end
  end

  @spec used_ids([map()]) :: [String.t()]
  defp used_ids(blocks), do: Enum.map(blocks, & &1.id)

  @spec next_id([String.t()]) :: String.t()
  defp next_id(ids) do
    ids
    |> Enum.map(&String.to_integer/1)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
    |> Integer.to_string()
  end

  @spec rewrite_block_id(String.t(), String.t()) :: String.t()
  defp rewrite_block_id(block, id) do
    Regex.replace(
      @id_line_regex,
      block,
      fn _match, prefix, quote, _old_id ->
        "#{prefix}#{quote}#{id}#{quote}"
      end,
      global: false
    )
  end
end
