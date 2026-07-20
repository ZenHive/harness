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
  @type conflict_result :: {:ok, String.t(), [rewrite()]} | {:error, :non_additive}

  @id_line_regex ~r/^(\s*id\s*=\s*)("?)(\d+)\2\s*$/m

  @doc """
  Rewrites new task blocks in `head_toml` whose ids collide with `base_toml`.
  """
  @spec rewrite_collisions(String.t(), String.t()) :: result()
  def rewrite_collisions(base_toml, head_toml) when is_binary(base_toml) and is_binary(head_toml) do
    case appended_task_blocks(base_toml, head_toml) do
      {:ok, additions} ->
        {rewritten, rewrites} = rewrite_branch_collisions(base_toml, additions)
        if rewrites == [], do: :unchanged, else: {:rewritten, base_toml <> rewritten, rewrites}

      :error ->
        :unchanged
    end
  end

  @doc """
  Combines target and branch task additions from one conflicted task file.

  Both sides must retain `base_toml` byte-for-byte and append only complete
  `[[task]]` blocks. Branch additions that reuse a target id are reassigned to
  the next available integer id.
  """
  @spec resolve_additive_conflict(String.t(), String.t(), String.t()) :: conflict_result()
  def resolve_additive_conflict(base_toml, target_toml, branch_toml)
      when is_binary(base_toml) and is_binary(target_toml) and is_binary(branch_toml) do
    with {:ok, _target_additions} <- appended_task_blocks(base_toml, target_toml),
         {:ok, branch_additions} <- appended_task_blocks(base_toml, branch_toml) do
      {rewritten_branch, rewrites} = rewrite_branch_collisions(target_toml, branch_additions)
      {:ok, target_toml <> rewritten_branch, rewrites}
    else
      :error -> {:error, :non_additive}
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

  @spec appended_task_blocks(String.t(), String.t()) :: {:ok, String.t()} | :error
  defp appended_task_blocks(base_toml, side_toml) do
    if String.starts_with?(side_toml, base_toml) do
      additions = String.replace_prefix(side_toml, base_toml, "")

      if additions == "" or complete_task_blocks?(additions), do: {:ok, additions}, else: :error
    else
      :error
    end
  end

  @spec complete_task_blocks?(String.t()) :: boolean()
  defp complete_task_blocks?(text) do
    blocks = task_blocks(text)
    blocks != [] and Enum.map_join(blocks, "", & &1.body) == text
  end

  @spec rewrite_branch_collisions(String.t(), String.t()) :: {String.t(), [rewrite()]}
  defp rewrite_branch_collisions(target_toml, branch_additions) do
    target_ids = target_toml |> task_blocks() |> used_ids()

    {rewritten, rewrites, _used} =
      Enum.reduce(task_blocks(branch_additions), {branch_additions, [], target_ids}, fn block, {text, acc, used} ->
        if block.id in used do
          next = next_id(used)
          updated = rewrite_block_id(block.body, next)
          {String.replace(text, block.body, updated, global: false), [%{from: block.id, to: next} | acc], [next | used]}
        else
          {text, acc, [block.id | used]}
        end
      end)

    {rewritten, Enum.reverse(rewrites)}
  end
end
