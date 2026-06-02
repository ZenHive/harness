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
    e ->
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

      attrs = %{name: name, payload: payload}
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
    e ->
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
    e ->
      Logger.warning("harness project registry: failed to delete #{name}: #{inspect(e)}")
      :ok
  end

  @spec decode_row(ProjectSchema.t()) :: {:ok, Project.t()} | {:error, term()}
  defp decode_row(%ProjectSchema{name: name, payload: payload}) when is_binary(payload) do
    case safe_binary_to_term(payload) do
      {:ok, %Project{name: ^name} = project} -> {:ok, migrate_payload(project)}
      {:ok, %Project{name: other}} -> {:error, {:name_mismatch, name, other}}
      {:ok, _other} -> {:error, {:invalid_payload, name}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_row(%ProjectSchema{name: name}), do: {:error, {:missing_payload, name}}

  # A payload serialized before Task 162 carries the deprecated `semantic_gate`
  # mode and lacks `review_green`. Rebuild it on the current struct shape so
  # field access never raises: :always / :auto_land_only ⇒ true, :off ⇒ false.
  @spec migrate_payload(struct()) :: Project.t()
  defp migrate_payload(%Project{} = project) do
    if Map.has_key?(project, :review_green) do
      project
    else
      legacy = Map.get(project, :semantic_gate, :off)

      fields =
        project
        |> Map.from_struct()
        |> Map.delete(:semantic_gate)
        |> Map.put(:review_green, legacy in [:always, :auto_land_only])

      struct!(Project, fields)
    end
  end

  # Payload is harness-owned term binary from upsert/1 — not untrusted input.
  # sobelow_skip ["Misc.BinToTerm"]
  @spec safe_binary_to_term(binary()) :: {:ok, term()} | {:error, term()}
  defp safe_binary_to_term(bin) when is_binary(bin) do
    {:ok, :erlang.binary_to_term(bin)}
  rescue
    ArgumentError -> {:error, :invalid_term}
  end
end
