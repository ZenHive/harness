defmodule Harness.LegacyTermImport do
  @moduledoc """
  One-time importer for legacy term-backed result and chat stores.

  This is the cutover bridge from `~/.harness/results` and `~/.harness/chats`
  into Postgres. Re-running is idempotent because the Postgres stores upsert by
  their natural keys.
  """

  alias Harness.Batch.Result, as: BatchResult
  alias Harness.CapabilityScore
  alias Harness.Chat.Store.Postgres, as: ChatPostgres
  alias Harness.Repo
  alias Harness.ResultStore
  alias Harness.ResultStore.Postgres, as: ResultPostgres
  alias Harness.Run.LogRecord
  alias Harness.TermCodec

  require Logger

  @default_results_root "~/.harness/results"
  @default_chats_root "~/.harness/chats"

  @type stats :: %{imported: non_neg_integer(), skipped: non_neg_integer()}
  @type summary :: %{
          runs_imported: non_neg_integer(),
          runs_skipped: non_neg_integer(),
          batches_imported: non_neg_integer(),
          batches_skipped: non_neg_integer(),
          capability_scores_imported: non_neg_integer(),
          capability_scores_skipped: non_neg_integer(),
          chats_imported: non_neg_integer(),
          chats_skipped: non_neg_integer()
        }

  @doc false
  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts) when is_list(opts) do
    Task.start_link(fn -> import_all(opts) end)
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :transient}
  end

  @doc "Imports legacy result and chat term files into Postgres."
  @spec import_all(keyword()) :: summary()
  def import_all(opts) when is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)
    results_root = opts |> Keyword.get(:results_root, @default_results_root) |> Path.expand()
    chats_root = opts |> Keyword.get(:chats_root, @default_chats_root) |> Path.expand()
    result_store = {ResultPostgres, repo: repo}
    postgres_opts = [repo: repo]

    runs = import_terms(Path.join(results_root, "runs"), LogRecord, &ResultStore.record_run(&1, result_store))
    batches = import_terms(Path.join(results_root, "batches"), BatchResult, &ResultStore.save_batch(&1, result_store))

    scores =
      import_terms(Path.join(results_root, "capability_scores"), CapabilityScore, fn score ->
        ResultStore.save_capability_score(score, result_store)
      end)

    chats = import_terms(chats_root, :chat_session, &ChatPostgres.import_session(&1, postgres_opts))

    %{
      runs_imported: runs.imported,
      runs_skipped: runs.skipped,
      batches_imported: batches.imported,
      batches_skipped: batches.skipped,
      capability_scores_imported: scores.imported,
      capability_scores_skipped: scores.skipped,
      chats_imported: chats.imported,
      chats_skipped: chats.skipped
    }
  end

  @spec import_terms(String.t(), module() | :chat_session, (term() -> term())) :: stats()
  defp import_terms(dir, expected, persist_fun) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".term"))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.reduce(%{imported: 0, skipped: 0}, &import_file(&1, expected, persist_fun, &2))

      {:error, :enoent} ->
        %{imported: 0, skipped: 0}

      {:error, reason} ->
        Logger.warning("harness legacy import: cannot read #{dir}: #{inspect(reason)}")
        %{imported: 0, skipped: 0}
    end
  end

  @spec import_file(String.t(), module() | :chat_session, (term() -> term()), stats()) :: stats()
  defp import_file(path, expected, persist_fun, acc) do
    case import_file_result(path, expected, persist_fun) do
      :imported -> %{acc | imported: acc.imported + 1}
      {:skipped, reason} -> log_skip(path, reason, acc)
    end
  end

  @spec import_file_result(String.t(), module() | :chat_session, (term() -> term())) ::
          :imported | {:skipped, term()}
  defp import_file_result(path, expected, persist_fun) do
    with {:ok, term} <- TermCodec.read_file(path),
         true <- expected_term?(term, expected),
         :ok <- persist_fun.(term) do
      :imported
    else
      false -> {:skipped, :cross_typed}
      {:error, reason} -> {:skipped, reason}
    end
  end

  @spec expected_term?(term(), module() | :chat_session) :: boolean()
  defp expected_term?(%{__struct__: mod}, mod), do: true

  defp expected_term?(%{session_id: id, messages: messages, updated_at: updated_at}, :chat_session),
    do: is_binary(id) and is_list(messages) and match?(%DateTime{}, updated_at)

  defp expected_term?(_term, _expected), do: false

  @spec log_skip(String.t(), term(), stats()) :: stats()
  defp log_skip(path, reason, acc) do
    Logger.warning("harness legacy import: skipped #{path}: #{inspect(reason)}")
    %{acc | skipped: acc.skipped + 1}
  end
end
