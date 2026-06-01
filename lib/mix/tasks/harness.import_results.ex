defmodule Mix.Tasks.Harness.ImportResults do
  @shortdoc "Import file-backed run/batch records into the Postgres result store"

  @moduledoc """
  One-shot cutover: reads `~/.harness/results` (or `--root`) and upserts every
  decodable `runs/*.term` and `batches/*.term` into `Harness.ResultStore.Postgres`.

      mix harness.import_results
      mix harness.import_results --root /path/to/results
      mix harness.import_results --repo MyApp.Repo

  Re-running is idempotent (upsert on `run_id` / `batch_id`). Corrupt or
  cross-typed term files are skipped, counted, and logged; exit status stays 0.
  """

  use Mix.Task

  alias Harness.Batch.Result, as: BatchResult
  alias Harness.ResultStore
  alias Harness.ResultStore.File, as: FileStore
  alias Harness.ResultStore.Postgres, as: PostgresStore
  alias Harness.Run.LogRecord

  require Logger

  @impl Mix.Task
  @spec run([term()]) :: :ok
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [root: :string, repo: :string])
    Mix.Task.run("app.start")

    root = opts[:root] || default_root()
    repo = repo_module(opts[:repo])

    if !Code.ensure_loaded?(repo) do
      Mix.raise("repo module #{inspect(repo)} is not loaded")
    end

    store_opts = [root: root, repo: repo]
    summary = import_all(store_opts)
    print_summary(summary)
    :ok
  end

  @type summary :: %{
          runs_imported: non_neg_integer(),
          runs_skipped: non_neg_integer(),
          batches_imported: non_neg_integer(),
          batches_skipped: non_neg_integer()
        }

  @spec import_all(keyword()) :: summary()
  defp import_all(opts) do
    root = Keyword.fetch!(opts, :root)
    postgres = {PostgresStore, Keyword.take(opts, [:repo])}

    runs_dir = Path.join(root, "runs")
    batches_dir = Path.join(root, "batches")

    run_stats = import_runs(runs_dir, postgres)
    batch_stats = import_batches(batches_dir, postgres)

    %{
      runs_imported: run_stats.imported,
      runs_skipped: run_stats.skipped,
      batches_imported: batch_stats.imported,
      batches_skipped: batch_stats.skipped
    }
  end

  @spec import_runs(String.t(), ResultStore.store()) :: %{imported: non_neg_integer(), skipped: non_neg_integer()}
  defp import_runs(dir, store) do
    import_terms(dir, ".term", LogRecord, &ResultStore.record_run/2, store)
  end

  @spec import_batches(String.t(), ResultStore.store()) :: %{imported: non_neg_integer(), skipped: non_neg_integer()}
  defp import_batches(dir, store) do
    import_terms(dir, ".term", BatchResult, &ResultStore.save_batch/2, store)
  end

  @spec import_terms(String.t(), String.t(), module(), (term(), ResultStore.store() -> term()), ResultStore.store()) ::
          %{imported: non_neg_integer(), skipped: non_neg_integer()}
  defp import_terms(dir, suffix, expected_mod, persist_fun, store) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, suffix))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.reduce(%{imported: 0, skipped: 0}, &import_file(&1, expected_mod, persist_fun, store, &2))

      {:error, :enoent} ->
        %{imported: 0, skipped: 0}

      {:error, reason} ->
        Logger.warning("harness import_results: cannot read #{dir}: #{inspect(reason)}")
        %{imported: 0, skipped: 0}
    end
  end

  @spec import_file(String.t(), module(), (term(), ResultStore.store() -> term()), ResultStore.store(), map()) ::
          %{imported: non_neg_integer(), skipped: non_neg_integer()}
  defp import_file(path, expected_mod, persist_fun, store, acc) do
    case import_file_result(path, expected_mod, persist_fun, store) do
      :imported -> %{acc | imported: acc.imported + 1}
      {:skipped, reason} -> log_skip(path, reason, acc)
    end
  end

  @spec import_file_result(String.t(), module(), (term(), ResultStore.store() -> term()), ResultStore.store()) ::
          :imported | {:skipped, term()}
  defp import_file_result(path, expected_mod, persist_fun, store) do
    case read_term(path) do
      {:ok, %{} = term} -> persist_decoded(term, expected_mod, persist_fun, store)
      {:error, reason} -> {:skipped, reason}
    end
  end

  @spec persist_decoded(term(), module(), (term(), ResultStore.store() -> term()), ResultStore.store()) ::
          :imported | {:skipped, term()}
  defp persist_decoded(term, expected_mod, persist_fun, store) do
    with true <- struct_type(term) == expected_mod,
         :ok <- persist_fun.(term, store) do
      :imported
    else
      false -> {:skipped, :cross_typed}
      {:error, reason} -> {:skipped, reason}
    end
  end

  @spec log_skip(String.t(), term(), map()) :: %{imported: non_neg_integer(), skipped: non_neg_integer()}
  defp log_skip(path, reason, acc) do
    Logger.warning("harness import_results: skipped #{path}: #{inspect(reason)}")
    %{acc | skipped: acc.skipped + 1}
  end

  @spec read_term(String.t()) :: {:ok, term()} | {:error, term()}
  defp read_term(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, :erlang.binary_to_term(body)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    ArgumentError -> {:error, {:invalid_term_file, path}}
  end

  @spec struct_type(struct()) :: module()
  defp struct_type(%{__struct__: mod}), do: mod

  @spec default_root() :: String.t()
  defp default_root do
    case_result =
      case Application.get_env(:harness, :result_store) do
        {FileStore, opts} when is_list(opts) -> Keyword.get(opts, :root, "~/.harness/results")
        _ -> "~/.harness/results"
      end

    Path.expand(case_result)
  end

  @spec repo_module(String.t() | nil) :: module()
  defp repo_module(nil), do: Harness.Repo
  defp repo_module(name), do: Module.concat([name])

  @spec print_summary(summary()) :: :ok
  defp print_summary(summary) do
    IO.puts(
      "Imported #{summary.runs_imported} run(s), #{summary.batches_imported} batch(es); " <>
        "skipped #{summary.runs_skipped} run file(s), #{summary.batches_skipped} batch file(s)."
    )
  end
end
