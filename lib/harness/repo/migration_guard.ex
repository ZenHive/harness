defmodule Harness.Repo.MigrationGuard do
  @moduledoc """
  Boot-time fail-fast guard against pending Ecto migrations.

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
  """

  alias Harness.Repo

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
    :ignore
  end

  @doc """
  Raises when `migrations` contains any pending (`:down`) entry; returns `:ok`
  otherwise. Takes the `Ecto.Migrator.migrations/1` result so callers (and tests)
  can supply a synthetic status list.
  """
  @spec check!([{:up | :down, integer(), String.t()}]) :: :ok
  def check!(migrations) do
    case Enum.filter(migrations, fn {status, _version, _name} -> status == :down end) do
      [] -> :ok
      pending -> raise pending_migration_error(pending)
    end
  end

  @spec pending_migration_error([{:down, integer(), String.t()}]) :: String.t()
  defp pending_migration_error(pending) do
    listed = Enum.map_join(pending, "\n", fn {_status, version, name} -> "  #{version} #{name}" end)

    "Harness.Repo has #{length(pending)} pending migration(s) — refusing to boot:\n" <>
      listed <>
      "\n\nRun `mix ecto.migrate` and restart. Booting with a drifted " <>
      "schema silently empties the project registry (see Harness.Repo.MigrationGuard)."
  end
end
