defmodule Harness.Dashboard.QA do
  @moduledoc "Read-only QA presentation from durable attempts and effective project settings."

  alias Harness.Audit.QA, as: Attempts
  alias Harness.Git
  alias Harness.Landing.Settings
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.ProjectRegistry.Schema.Project, as: ProjectSchema
  alias Harness.Projects.DispatchQA.Catalog
  alias Harness.Repo
  alias Harness.SafeTerm

  @doc "Reads a project's bounded history and rollout facts without transcripts or repository inventory."
  @spec project(Project.t(), pos_integer()) :: map()
  def project(project, limit \\ 1) do
    facts = Attempts.list(project.name, limit)
    revision = observed_revision(project)
    {attempts, pending} = split_facts(facts)
    latest = List.first(attempts)
    entry = Catalog.entry(project.name)

    %{
      id: project.name,
      project: project,
      revision: revision,
      attempts: attempts,
      pending: pending,
      latest: latest,
      matched: matched?(latest, project, revision),
      status: status(pending, latest, facts),
      facts: facts,
      configured: configured?(project),
      adoption: adoption(project, entry),
      catalog: entry,
      persisted: persisted(project),
      override: Settings.overrides()[project.name]
    }
  end

  @doc "Loads only the selected project, or a bounded page of registered projects."
  @spec page(String.t(), String.t(), non_neg_integer()) :: map()
  def page(name, status, offset) do
    projects = Enum.sort_by(ProjectRegistry.list(), & &1.name)
    selected = Enum.filter(projects, &(name == "" or &1.name == name))
    # Status filtering reads summaries only; evidence is fetched on explicit request.
    rows = selected |> Enum.map(&project/1) |> Enum.filter(&matches?(&1, status))
    %{names: Enum.map(projects, & &1.name), rows: Enum.slice(rows, offset, 25), total: length(rows)}
  end

  @spec matches?(map(), String.t()) :: boolean()
  defp matches?(_row, ""), do: true
  defp matches?(row, "configured"), do: row.configured
  defp matches?(row, "not-configured"), do: not row.configured

  defp matches?(row, status) when status in ["passed", "failed", "incomplete"],
    do: not is_nil(row.latest) and row.latest.status == status

  defp matches?(row, status), do: row.status == status

  @spec split_facts(term()) :: {[map()], [map()]}
  defp split_facts({:ok, data}), do: {data.attempts, data.pending}
  defp split_facts(_facts), do: {[], []}

  @spec configured?(Project.t()) :: boolean()
  defp configured?(project), do: is_binary(project.qa_command) and project.qa_command != ""

  @spec matched?(map() | nil, Project.t(), String.t() | nil) :: boolean()
  defp matched?(latest, project, revision) when is_map(latest) and is_binary(revision) do
    latest.command == project.qa_command and latest.target_branch == project.target_branch and
      latest.revision == revision
  end

  defp matched?(_latest, _project, _revision), do: false

  @spec status([map()], map() | nil, term()) :: String.t()
  defp status(_, _, {:error, _}), do: "unavailable"

  defp status([_ | _] = pending, _, _),
    do: if(Enum.any?(pending, &(&1.status == "running")), do: "running", else: "queued")

  defp status([], nil, _), do: "not-run"
  defp status([], latest, _), do: latest.status

  @spec adoption(Project.t(), map() | nil) :: String.t()
  defp adoption(_project, nil), do: "No rollout mapping available; adoption unverified"

  defp adoption(project, entry) do
    cond do
      project.check_command != entry.dispatch -> "Dispatch checks retained; focused command not adopted"
      project.qa_command != entry.qa -> "Focused command configured; full-QA command differs from rollout mapping"
      true -> "Focused dispatch command configured"
    end
  end

  @spec observed_revision(Project.t()) :: String.t() | nil
  defp observed_revision(project) do
    with {:ok, repo} <- Project.local_repo_path(project),
         {:ok, target} <- Project.target_branch(project),
         {:ok, sha} <- Git.run(["rev-parse", "--verify", "refs/remotes/origin/" <> target], repo) do
      String.trim(sha)
    else
      _ -> nil
    end
  end

  @spec persisted(Project.t()) :: term()
  defp persisted(project) do
    with %ProjectSchema{} = row <- Repo.get(ProjectSchema, project.name),
         {:ok, %Project{} = stored} <- SafeTerm.decode(row.payload) do
      fields = [:check_command, :qa_command, :landing_policy, :target_branch]
      %{registered: Map.take(stored, fields), effective: Map.take(project, fields)}
    else
      nil -> {:error, :not_persisted}
      other -> {:error, other}
    end
  rescue
    error in [RuntimeError, DBConnection.ConnectionError, DBConnection.OwnershipError, Postgrex.Error] ->
      {:error, Exception.message(error)}
  end
end
