defmodule Harness.DepFreshnessStore.Postgres do
  @moduledoc false

  @behaviour Harness.DepFreshnessStore

  import Ecto.Query, only: [from: 2, order_by: 3]

  alias Harness.DepFreshness.Row
  alias Harness.DepFreshness.Snapshot
  alias Harness.DepFreshnessStore.Schema.Snapshot, as: SnapshotSchema
  alias Harness.Repo

  @persistence_errors [
    RuntimeError,
    DBConnection.ConnectionError,
    DBConnection.OwnershipError,
    Postgrex.Error,
    Ecto.ConstraintError,
    Ecto.StaleEntryError,
    Ecto.Query.CastError,
    Ecto.QueryError,
    Ecto.ChangeError,
    ArgumentError
  ]

  @impl Harness.DepFreshnessStore
  @spec record_snapshot(Snapshot.t(), keyword()) :: :ok | {:error, term()}
  def record_snapshot(%Snapshot{} = snapshot, opts) when is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)
    attrs = snapshot_to_attrs(snapshot)
    schema = %SnapshotSchema{project_name: snapshot.project_name}
    changeset = SnapshotSchema.changeset(schema, attrs)

    case repo.insert(changeset, on_conflict: :replace_all, conflict_target: :project_name) do
      {:ok, _} -> :ok
      {:error, cs} -> {:error, {:changeset, cs.errors}}
    end
  rescue
    e in @persistence_errors -> {:error, e}
  end

  @impl Harness.DepFreshnessStore
  @spec fetch_snapshot(String.t(), keyword()) :: {:ok, Snapshot.t()} | {:error, :not_found | term()}
  def fetch_snapshot(project_name, opts) when is_binary(project_name) and is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)

    case repo.get(SnapshotSchema, project_name) do
      nil -> {:error, :not_found}
      schema -> {:ok, schema_to_snapshot(schema)}
    end
  rescue
    e in @persistence_errors -> {:error, e}
  end

  @impl Harness.DepFreshnessStore
  @spec list_snapshots(keyword(), keyword()) :: {:ok, [Snapshot.t()]} | {:error, term()}
  def list_snapshots(filters, opts) when is_list(filters) and is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)
    project_name = Keyword.get(filters, :project_name)

    query =
      if is_binary(project_name) do
        from(s in SnapshotSchema, where: s.project_name == ^project_name)
      else
        SnapshotSchema
      end

    snapshots =
      query
      |> order_by([s], asc: s.project_name)
      |> repo.all()
      |> Enum.map(&schema_to_snapshot/1)

    {:ok, snapshots}
  rescue
    e in @persistence_errors -> {:error, e}
  end

  @spec snapshot_to_attrs(Snapshot.t()) :: map()
  defp snapshot_to_attrs(%Snapshot{} = snapshot) do
    %{
      project_name: snapshot.project_name,
      language: snapshot.language,
      checked_at: snapshot.checked_at,
      outdated_count: snapshot.outdated_count,
      rows: Enum.map(snapshot.rows, &Row.to_map/1)
    }
  end

  @spec schema_to_snapshot(SnapshotSchema.t()) :: Snapshot.t()
  defp schema_to_snapshot(%SnapshotSchema{} = schema) do
    rows =
      (schema.rows || [])
      |> Enum.map(&Row.from_map/1)
      |> Enum.sort_by(& &1.name)

    %Snapshot{
      project_name: schema.project_name,
      language: schema.language,
      checked_at: schema.checked_at,
      outdated_count: schema.outdated_count || Snapshot.outdated_count(rows),
      rows: rows
    }
  end
end
