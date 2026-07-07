defmodule Harness.SuiteHealthStore.Postgres do
  @moduledoc false

  @behaviour Harness.SuiteHealthStore

  import Ecto.Query, only: [from: 2, order_by: 3]

  alias Harness.Repo
  alias Harness.SuiteHealth.Result
  alias Harness.SuiteHealthStore.Schema.Result, as: ResultSchema

  @persistence_errors Harness.Store.persistence_errors()

  @impl Harness.SuiteHealthStore
  @spec record_result(Result.t(), keyword()) :: :ok | {:error, term()}
  def record_result(%Result{} = result, opts) when is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)
    attrs = result_to_attrs(result)
    schema = %ResultSchema{project_name: result.project_name}
    changeset = ResultSchema.changeset(schema, attrs)

    case repo.insert(changeset, on_conflict: :replace_all, conflict_target: :project_name) do
      {:ok, _} -> :ok
      {:error, cs} -> {:error, {:changeset, cs.errors}}
    end
  rescue
    e in @persistence_errors -> {:error, e}
  end

  @impl Harness.SuiteHealthStore
  @spec fetch_result(String.t(), keyword()) :: {:ok, Result.t()} | {:error, :not_found | term()}
  def fetch_result(project_name, opts) when is_binary(project_name) and is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)

    case repo.get(ResultSchema, project_name) do
      nil -> {:error, :not_found}
      schema -> {:ok, schema_to_result(schema)}
    end
  rescue
    e in @persistence_errors -> {:error, e}
  end

  @impl Harness.SuiteHealthStore
  @spec list_results(keyword(), keyword()) :: {:ok, [Result.t()]} | {:error, term()}
  def list_results(filters, opts) when is_list(filters) and is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)
    project_name = Keyword.get(filters, :project_name)

    query =
      if is_binary(project_name) do
        from(r in ResultSchema, where: r.project_name == ^project_name)
      else
        ResultSchema
      end

    results =
      query
      |> order_by([r], asc: r.project_name)
      |> repo.all()
      |> Enum.map(&schema_to_result/1)

    {:ok, results}
  rescue
    e in @persistence_errors -> {:error, e}
  end

  @spec result_to_attrs(Result.t()) :: map()
  defp result_to_attrs(%Result{} = result) do
    %{
      project_name: result.project_name,
      checked_at: result.checked_at,
      passed: result.passed,
      exit_code: result.exit_code,
      command: result.command,
      base_sha: result.base_sha,
      skip_reason: result.skip_reason,
      failing_tests: result.failing_tests,
      languages: result.languages
    }
  end

  @spec schema_to_result(ResultSchema.t()) :: Result.t()
  defp schema_to_result(%ResultSchema{} = schema) do
    %Result{
      project_name: schema.project_name,
      checked_at: schema.checked_at,
      passed: schema.passed,
      exit_code: schema.exit_code,
      command: schema.command,
      base_sha: schema.base_sha,
      skip_reason: schema.skip_reason,
      failing_tests: schema.failing_tests || [],
      languages: schema.languages || ""
    }
  end
end
