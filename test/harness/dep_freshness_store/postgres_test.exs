defmodule Harness.DepFreshnessStore.PostgresTest do
  use ExUnit.Case, async: true

  alias Harness.DepFreshness.Row
  alias Harness.DepFreshness.Snapshot
  alias Harness.DepFreshnessStore.Postgres
  alias Harness.DepFreshnessStore.PostgresTest
  alias Harness.DepFreshnessStore.Schema.Snapshot, as: SnapshotSchema

  defmodule InsertRepo do
    @spec insert(Ecto.Changeset.t(), keyword()) :: {:ok, SnapshotSchema.t()}
    def insert(changeset, _opts), do: {:ok, Ecto.Changeset.apply_changes(changeset)}
  end

  defmodule ErrorRepo do
    @spec insert(Ecto.Changeset.t(), keyword()) :: {:error, Ecto.Changeset.t()}
    def insert(changeset, _opts), do: {:error, changeset}
  end

  defmodule GetRepo do
    @spec get(module(), String.t()) :: SnapshotSchema.t() | nil
    def get(SnapshotSchema, "demo"), do: PostgresTest.schema("demo", nil)
    def get(SnapshotSchema, _other), do: nil
  end

  defmodule AllRepo do
    @spec all(Ecto.Query.t()) :: [SnapshotSchema.t()]
    def all(_query) do
      [
        PostgresTest.schema("beta", 1),
        PostgresTest.schema("alpha", 0)
      ]
    end
  end

  defmodule RaisingRepo do
    @spec get(module(), String.t()) :: no_return()
    def get(_schema, _project_name), do: raise("db unavailable")
  end

  test "record_snapshot/2 encodes rows into the schema" do
    snapshot =
      Snapshot.build("demo", "elixir", [
        %Row{name: "req", current_version: "0.6.1", latest_version: "0.6.2", constraint_allowed: true}
      ])

    assert :ok = Postgres.record_snapshot(snapshot, repo: InsertRepo)
  end

  test "record_snapshot/2 returns changeset errors" do
    snapshot = Snapshot.build("demo", "elixir", [])

    assert {:error, {:changeset, errors}} = Postgres.record_snapshot(snapshot, repo: ErrorRepo)
    assert is_list(errors)
  end

  test "fetch_snapshot/2 decodes stored rows and handles misses" do
    assert {:ok, snapshot} = Postgres.fetch_snapshot("demo", repo: GetRepo)
    assert snapshot.outdated_count == 1
    assert [%Row{name: "req"}] = snapshot.rows

    assert {:error, :not_found} = Postgres.fetch_snapshot("missing", repo: GetRepo)
  end

  test "list_snapshots/2 decodes all rows" do
    assert {:ok, snapshots} = Postgres.list_snapshots([], repo: AllRepo)
    assert Enum.map(snapshots, & &1.project_name) == ["beta", "alpha"]
  end

  test "persistence errors are returned" do
    assert {:error, %RuntimeError{message: "db unavailable"}} = Postgres.fetch_snapshot("demo", repo: RaisingRepo)
  end

  @spec schema(String.t(), integer() | nil) :: SnapshotSchema.t()
  def schema(project_name, outdated_count) do
    %SnapshotSchema{
      project_name: project_name,
      language: "elixir",
      checked_at: DateTime.utc_now(),
      outdated_count: outdated_count,
      rows: [
        %{
          "name" => "req",
          "current_version" => "0.6.1",
          "latest_version" => "0.6.2",
          "constraint_allowed" => true
        }
      ]
    }
  end
end
