defmodule Mix.Tasks.Harness.Worktree.Reclaim do
  @shortdoc "Plans or applies reclaim of landed harness run branches and worktree orphans"

  @moduledoc """
  Conservative maintenance for leftover `harness/<run-id>` branches and
  filesystem worktree orphans.

  Dry-run by default: prints leftovers whose commits are reachable from each
  registered project's target, plus unregistered directories and stale
  `.git` back-links. Coverage lines name inspected, skipped, and failed
  projects so an empty leftover list is not mistaken for a finished scan.
  Pass `--apply` to reclaim/repair. Apply refuses and makes no mutations
  when the selected inspection is incomplete.

  Live, retained, held, failed, and unlanded sole-copy leftovers are never
  deleted.

      mix harness.worktree.reclaim
      mix harness.worktree.reclaim --apply
  """

  use Mix.Task

  alias Harness.Worktree.Reclaim

  @fact_bound 240

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    Mix.Task.run("app.start")
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [apply: :boolean])
    emit(dry_run: not Keyword.get(opts, :apply, false))
  end

  @doc false
  @spec emit(keyword()) :: :ok
  def emit(reclaim_opts) do
    case Reclaim.run(reclaim_opts) do
      {:ok, report} ->
        IO.puts(render(report))
        :ok

      {:error, {:incomplete_inspection, report}} ->
        IO.puts(render(report))
        Mix.raise("incomplete inspection; refusing apply")
    end
  end

  @spec render(Reclaim.report()) :: String.t()
  defp render(report) do
    mode = if report.dry_run, do: "dry-run", else: "apply"
    completeness = if report.complete?, do: "complete", else: "incomplete"

    [
      "harness worktree reclaim (#{mode}, #{completeness}): #{length(report.items)} leftover(s)",
      Enum.map(report.inspected, &render_inspected/1),
      Enum.map(report.skipped, &render_skipped/1),
      Enum.map(report.items, &render_item/1),
      if(report.applied == [], do: [], else: ["applied: #{length(report.applied)}"]),
      Enum.map(report.errors, &render_error/1)
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  @spec render_inspected(Reclaim.inspected()) :: String.t()
  defp render_inspected(entry) do
    bound("inspected: #{entry.project} repo=#{entry.repo} target=#{entry.target}")
  end

  @spec render_skipped(Reclaim.skipped()) :: String.t()
  defp render_skipped(entry) do
    bound("skipped: #{entry.project} #{inspect(entry.reason)}")
  end

  @spec render_item(Reclaim.item()) :: String.t()
  defp render_item(item) do
    loc = item[:branch] || item[:path] || "?"
    "  #{item.action} #{item.reason} #{loc}"
  end

  @spec render_error(Reclaim.inspection_error() | {Reclaim.item(), term()}) :: String.t()
  defp render_error(%{scope: scope} = error) do
    bound("error: #{scope} #{error[:project] || "-"} #{inspect(error.reason)}")
  end

  defp render_error({item, reason}) do
    bound("error: #{item[:run_id] || item[:path]} #{inspect(reason)}")
  end

  @spec bound(String.t()) :: String.t()
  defp bound(text) do
    if String.length(text) <= @fact_bound do
      text
    else
      String.slice(text, 0, @fact_bound) <> "…"
    end
  end
end
