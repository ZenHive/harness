defmodule Mix.Tasks.Harness.ImportResults do
  @shortdoc "Import legacy result/chat term records into Postgres"

  @moduledoc """
  One-shot cutover: reads `~/.harness/results` (or `--root`) and
  `~/.harness/chats` (or `--chats-root`) and upserts every decodable term file
  into the Postgres stores.

      mix harness.import_results
      mix harness.import_results --root /path/to/results
      mix harness.import_results --repo MyApp.Repo
      mix harness.import_results --root /path/to/results --chats-root /path/to/chats

  Re-running is idempotent. Corrupt or cross-typed term files are skipped,
  counted, and logged; exit status stays 0.
  """

  use Mix.Task

  alias Harness.LegacyTermImport

  @impl Mix.Task
  @spec run([term()]) :: :ok
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [root: :string, chats_root: :string, repo: :string])
    Mix.Task.run("app.start")

    root = opts[:root] || default_root()
    repo = repo_module(opts[:repo])

    if !Code.ensure_loaded?(repo) do
      Mix.raise("repo module #{inspect(repo)} is not loaded")
    end

    import_opts = [results_root: root, chats_root: opts[:chats_root] || "~/.harness/chats", repo: repo]
    summary = LegacyTermImport.import_all(import_opts)
    print_summary(summary)
    :ok
  end

  @spec default_root() :: String.t()
  defp default_root do
    Path.expand("~/.harness/results")
  end

  @spec repo_module(String.t() | nil) :: module()
  defp repo_module(nil), do: Harness.Repo
  defp repo_module(name), do: Module.concat([name])

  @spec print_summary(LegacyTermImport.summary()) :: :ok
  defp print_summary(summary) do
    IO.puts(
      "Imported #{summary.runs_imported} run(s), #{summary.batches_imported} batch(es); " <>
        "#{summary.capability_scores_imported} capability score(s), #{summary.chats_imported} chat(s); " <>
        "skipped #{summary.runs_skipped} run file(s), #{summary.batches_skipped} batch file(s), " <>
        "#{summary.capability_scores_skipped} score file(s), #{summary.chats_skipped} chat file(s)."
    )
  end
end
