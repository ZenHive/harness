defmodule Harness.ProjectRegistry.Persistence do
  @moduledoc false

  import Ecto.Query

  alias Harness.Project
  alias Harness.ProjectRegistry.Schema.Project, as: ProjectSchema
  alias Harness.Repo

  require Logger

  @doc false
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:harness, :repo_enabled, true)
  end

  # A schema/migration drift (a column or table the code references but the DB
  # lacks) must NOT be swallowed into an empty registry — re-raise it so it fails
  # loudly, the same intent the boot-time Harness.Repo.MigrationGuard enforces. The
  # soft rescue stays for genuinely-tolerable errors (e.g. a transient connection
  # blip), which legitimately degrade to empty/no-op.
  @structural_pg_codes [:undefined_column, :undefined_table]

  # DB FAILURES the soft rescue degrades over (connection blip, constraint, bad
  # query, param encoding). Postgrex.Error MUST stay listed so reraise_structural!
  # still sees schema-drift codes and fails loud. Programmer-error exceptions are
  # absent, so a code bug crashes rather than silently degrading the registry.
  @db_errors [
    # RuntimeError covers the repo-not-started lookup raise — a legitimate
    # "DB unavailable" failure to degrade over, not a bug. (Not a Postgrex.Error,
    # so reraise_structural! lets it through to the soft degrade.)
    RuntimeError,
    DBConnection.ConnectionError,
    DBConnection.OwnershipError,
    Postgrex.Error,
    Ecto.ConstraintError,
    Ecto.QueryError,
    ArgumentError
  ]

  @doc false
  @spec list() :: [Project.t()]
  def list do
    if enabled?() do
      from(p in ProjectSchema, order_by: [asc: p.name])
      |> Repo.all()
      |> decode_rows()
    else
      []
    end
  rescue
    e in @db_errors ->
      reraise_structural!(e, __STACKTRACE__)
      Logger.warning("harness project registry: failed to load persisted projects: #{inspect(e)}")
      []
  end

  @spec decode_rows([ProjectSchema.t()]) :: [Project.t()]
  defp decode_rows(rows) do
    rows
    |> Enum.reduce([], fn row, acc ->
      case decode_row(row) do
        {:ok, %Project{} = project} -> [project | acc]
        {:error, reason} -> skip_invalid_row(row, reason, acc)
      end
    end)
    |> Enum.reverse()
  end

  @spec skip_invalid_row(ProjectSchema.t(), term(), [Project.t()]) :: [Project.t()]
  defp skip_invalid_row(row, reason, acc) do
    Logger.warning("harness project registry: skipping invalid persisted row #{inspect(row.name)}: #{inspect(reason)}")

    acc
  end

  @doc false
  @spec upsert(Project.t()) :: :ok
  def upsert(%Project{name: name} = project) do
    if enabled?() do
      payload = :erlang.term_to_binary(project)

      attrs = %{name: name, payload: payload, warm_paths: project.warm_paths}
      schema = %ProjectSchema{name: name}
      changeset = ProjectSchema.changeset(schema, attrs)

      case Repo.insert(changeset, on_conflict: :replace_all, conflict_target: :name) do
        {:ok, _} ->
          :ok

        {:error, cs} ->
          Logger.warning("harness project registry: failed to persist #{name}: #{inspect(cs.errors)}")

          :ok
      end
    else
      :ok
    end
  rescue
    e in @db_errors ->
      reraise_structural!(e, __STACKTRACE__)
      Logger.warning("harness project registry: failed to persist #{project.name}: #{inspect(e)}")
      :ok
  end

  @doc false
  @spec delete(String.t()) :: :ok
  def delete(name) when is_binary(name) do
    if enabled?() do
      {_count, _} = Repo.delete_all(from(p in ProjectSchema, where: p.name == ^name))
      :ok
    else
      :ok
    end
  rescue
    e in @db_errors ->
      reraise_structural!(e, __STACKTRACE__)
      Logger.warning("harness project registry: failed to delete #{name}: #{inspect(e)}")
      :ok
  end

  # Re-raise a structural schema/migration drift (undefined column/table); return
  # :ok for every other error so the caller's soft rescue degrades as before.
  @spec reraise_structural!(Exception.t(), Exception.stacktrace()) :: :ok
  defp reraise_structural!(%Postgrex.Error{postgres: %{code: code}} = error, stacktrace)
       when code in @structural_pg_codes do
    reraise(error, stacktrace)
  end

  defp reraise_structural!(_error, _stacktrace), do: :ok

  @spec decode_row(ProjectSchema.t()) :: {:ok, Project.t()} | {:error, term()}
  defp decode_row(%ProjectSchema{name: name, payload: payload, warm_paths: warm_paths}) when is_binary(payload) do
    case decode_term(payload) do
      {:ok, %Project{name: ^name} = project} ->
        {:ok, %{rebuild_on_current_shape(project) | warm_paths: warm_paths || []}}

      {:ok, %Project{name: other}} ->
        {:error, {:name_mismatch, name, other}}

      {:ok, _other} ->
        {:error, {:invalid_payload, name}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_row(%ProjectSchema{name: name}), do: {:error, {:missing_payload, name}}

  # A payload serialized by an older harness may carry deleted fields
  # (check_stacks, review_green) and lack newer ones (check_command). Rebuild on
  # the current struct shape: known fields survive, unknown fields drop, missing
  # fields take struct defaults — field access never raises.
  @spec rebuild_on_current_shape(struct()) :: Project.t()
  defp rebuild_on_current_shape(%Project{} = project) do
    struct(Project, Map.from_struct(project))
  end

  # Payloads are harness-owned database blobs written by upsert/1.
  # sobelow_skip ["Misc.BinToTerm"]
  @spec decode_term(binary()) :: {:ok, term()} | {:error, :invalid_term}
  defp decode_term(payload) do
    {:ok, :erlang.binary_to_term(payload)}
  rescue
    ArgumentError -> {:error, :invalid_term}
  end
end
