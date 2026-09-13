defmodule Mix.Tasks.Harness.Worktree.Reclaim do
  @shortdoc "Plans or applies reclaim of landed harness run branches and worktree orphans"

  @moduledoc """
  Conservative maintenance for leftover `harness/<run-id>` branches and
  filesystem worktree orphans.

  Dry-run by default: prints leftovers whose commits are reachable from each
  registered project's target, plus unregistered directories and stale
  `.git` back-links. Pass `--apply` to reclaim/repair.

  Live, retained, held, failed, and unlanded sole-copy leftovers are never
  deleted.

      mix harness.worktree.reclaim
      mix harness.worktree.reclaim --apply
  """

  use Mix.Task

  alias Harness.Worktree.Reclaim

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    Mix.Task.run("app.start")
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [apply: :boolean])
    dry_run? = not Keyword.get(opts, :apply, false)
    {:ok, report} = Reclaim.run(dry_run: dry_run?)
    IO.puts(render(report))
    :ok
  end

  @spec render(Reclaim.report()) :: String.t()
  defp render(%{dry_run: dry_run?, items: items, applied: applied, errors: errors}) do
    mode = if dry_run?, do: "dry-run", else: "apply"

    [
      "harness worktree reclaim (#{mode}): #{length(items)} leftover(s)",
      Enum.map(items, &render_item/1),
      if(applied == [], do: [], else: ["applied: #{length(applied)}"]),
      Enum.map(errors, fn {item, reason} ->
        "error: #{item[:run_id] || item[:path]} #{inspect(reason)}"
      end)
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  @spec render_item(Reclaim.item()) :: String.t()
  defp render_item(item) do
    loc = item[:branch] || item[:path] || "?"
    "  #{item.action} #{item.reason} #{loc}"
  end
end
