defmodule Harness.Repo.MigrationGuard do
  @moduledoc """
  Boot-time fail-fast guard against pending Ecto migrations, plus a soft
  pending-migration listing for persist-failure warnings (Task 370).

  A one-shot supervised child (started after `Harness.Repo`, only when
  `repo_enabled: true`) that compares applied vs available migrations and
  **raises** if any are pending — the node refuses to boot rather than run with a
  schema the code no longer matches.

  This exists because a forgotten `mix ecto.migrate` is otherwise *silent*: the
  schema/queries reference a column the table lacks, every query fails with a
  Postgrex `undefined_column`/`undefined_table`, and the soft `rescue` clauses in
  the persistence layer degrade that into empty results — a healthy-looking node
  with an empty `Harness.ProjectRegistry`. A pending migration that took down the
  project registry (warm_paths, 2026-06-11) is the motivating incident. A hard
  boot failure makes the drift impossible to miss.

  After a clean boot check, spilled settle-time run records
  (`Harness.ResultStore.DeadLetter`) are replayed once so a prior drift window
  recovers automatically without waiting for the next settle.

  Long-lived nodes can still drift *after* boot (code reload of a newly landed
  schema while the DB is unmigrated). `pending/0` / `pending_labels/0` name the
  unapplied migrations for loud persist-failure warnings; they never auto-migrate.
  """

  alias Harness.Repo
  alias Harness.ResultStore

  require Logger

  @typedoc "One pending (`:down`) migration as `{version, name}`."
  @type pending :: {integer(), String.t()}

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg) do
    # reach:disable-next-line fixed_shape_map — standard OTP Supervisor.child_spec/1 literal
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :temporary, type: :worker}
  end

  @doc false
  @spec start_link() :: :ignore
  def start_link do
    check!(Ecto.Migrator.migrations(Repo))
    # Best-effort: recover any settle-time records spilled during a prior drift
    # window now that the schema matches code again.
    _ = ResultStore.replay_spilled()
    :ignore
  end

  @doc """
  Raises when `migrations` contains any pending (`:down`) entry; returns `:ok`
  otherwise. Takes the `Ecto.Migrator.migrations/1` result so callers (and tests)
  can supply a synthetic status list.
  """
  @spec check!([{:up | :down, integer(), String.t()}]) :: :ok
  def check!(migrations) do
    case pending_from(migrations) do
      [] -> :ok
      pending -> raise pending_migration_error(pending)
    end
  end

  @doc """
  Returns pending (`:down`) migrations as `{version, name}` pairs.

  Soft counterpart to `check!/1` for persist-failure warnings (Task 370). When
  the Repo is unavailable or `repo_enabled: false`, returns `[]` rather than
  raising — callers surface whatever listing is available.
  """
  @spec pending() :: [pending()]
  def pending do
    if Application.get_env(:harness, :repo_enabled, true) and repo_ready?() do
      pending_from(Ecto.Migrator.migrations(Repo))
    else
      []
    end
  rescue
    e in [DBConnection.ConnectionError, DBConnection.OwnershipError, Postgrex.Error, RuntimeError] ->
      Logger.debug("harness migration guard: pending listing failed: #{inspect(e)}")
      []
  end

  @doc """
  Human-readable labels for `pending/0` (`\"<version> <name>\"`), for warnings and
  notification payloads.
  """
  @spec pending_labels() :: [String.t()]
  def pending_labels do
    Enum.map(pending(), fn {version, name} -> "#{version} #{name}" end)
  end

  @doc false
  @spec pending_from([{:up | :down, integer(), String.t()}]) :: [pending()]
  def pending_from(migrations) when is_list(migrations) do
    migrations
    |> Enum.filter(fn {status, _version, _name} -> status == :down end)
    |> Enum.map(fn {_status, version, name} -> {version, name} end)
  end

  @spec repo_ready?() :: boolean()
  defp repo_ready?, do: is_pid(Process.whereis(Repo))

  @spec pending_migration_error([pending()]) :: String.t()
  defp pending_migration_error(pending) do
    listed = Enum.map_join(pending, "\n", fn {version, name} -> "  #{version} #{name}" end)

    "Harness.Repo has #{length(pending)} pending migration(s) — refusing to boot:\n" <>
      listed <>
      "\n\nRun `mix ecto.migrate` and restart. Booting with a drifted " <>
      "schema silently empties the project registry (see Harness.Repo.MigrationGuard)."
  end
end
