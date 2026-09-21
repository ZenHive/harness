defmodule Harness.Insights.ProjectEvidence do
  @moduledoc "Revision-pinned, allowlisted Git evidence; never reads working files or follows symlinks."

  alias Harness.Git
  alias Harness.Insights.Evidence
  alias Harness.Project

  @max_bytes 2_000_000
  @max_references 64
  @workflow ~w(CLAUDE.md AGENTS.md priv/includes/harness-workflow.md)

  @doc "Snapshots committed intent, workflow and explicitly referenced verification documents."
  @spec sources(Project.t()) :: [map()]
  def sources(project) do
    repo = Project.repo_path(project)
    revision = revision(repo)
    roadmap_revision = revision(project.roadmap_path)

    roadmap =
      file(project, project.roadmap_path, roadmap_revision, "roadmap/tasks.toml", "current_intent", "registered roadmap")

    references =
      ~r{docs/verification/[A-Za-z0-9_./-]+\.(?:json|md|txt|log)(?![A-Za-z0-9_./-])}
      |> Regex.scan(roadmap["content"])
      |> List.flatten()
      |> Enum.filter(&safe_path?/1)
      |> Enum.uniq()
      |> Enum.sort()

    workflow = Enum.map(@workflow, &file(project, repo, revision, &1, "current_workflow", "canonical workflow allowlist"))

    repairs =
      references
      |> Enum.take(@max_references)
      |> Enum.map(
        &file(project, repo, revision, &1, "repair_evidence", "referenced by roadmap/tasks.toml at #{roadmap_revision}")
      )

    catalog =
      snapshot(
        project.name,
        revision,
        "reference_catalog",
        Jason.encode!(%{paths: references, limit: @max_references}),
        %{
          "authority" => "catalog",
          "provenance" => "literal verification references in committed roadmap"
        }
      )

    catalog =
      Map.update!(catalog, "availability", fn availability ->
        cond do
          roadmap["availability"] == "unavailable" -> "unavailable"
          length(references) > @max_references -> "truncated"
          true -> availability
        end
      end)

    [roadmap, catalog | workflow] ++ repairs
  end

  @spec safe_path?(String.t()) :: boolean()
  defp safe_path?(path), do: Enum.all?(Path.split(path), &(&1 not in [".", ".."]))

  @spec revision(String.t()) :: String.t() | nil
  defp revision(repo) do
    case Git.run(["rev-parse", "--verify", "HEAD^{commit}"], repo) do
      {:ok, sha} -> String.trim(sha)
      {:error, _} -> nil
    end
  end

  @spec file(Project.t(), String.t(), String.t() | nil, String.t(), String.t(), String.t()) :: map()
  defp file(project, repo, revision, path, authority, provenance) do
    {content, reason} = blob(repo, revision, path)

    snapshot(project.name, revision, path, content, %{
      "path" => path,
      "authority" => authority,
      "provenance" => provenance,
      "unavailable_reason" => reason
    })
  end

  @spec blob(String.t(), String.t() | nil, String.t()) :: {String.t() | nil, String.t() | nil}
  defp blob(_repo, nil, _path), do: {nil, "repository revision unavailable"}

  defp blob(repo, revision, path) do
    with {:ok, entry} <- Git.run(["ls-tree", revision, "--", path], repo),
         [mode, "blob", hash, ^path] <- String.split(String.trim(entry), ~r/\s+/, parts: 4),
         true <- mode in ["100644", "100755"],
         {:ok, size} <- Git.run(["cat-file", "-s", hash], repo),
         {bytes, ""} <- Integer.parse(String.trim(size)),
         true <- bytes <= @max_bytes,
         {:ok, content} <- Git.run(["cat-file", "blob", hash], repo),
         true <- String.valid?(content) do
      {content, nil}
    else
      _ -> {nil, "missing, non-regular, oversized or non-UTF-8 committed blob"}
    end
  end

  @doc "Builds an immutable source with revision and provenance retained in citations."
  @spec snapshot(String.t(), String.t() | nil, String.t(), String.t() | nil, map()) :: map()
  def snapshot(project, revision, field, content, metadata) do
    hash = :sha256 |> :crypto.hash(content || "") |> Base.encode16()
    id = "project/#{project}/#{revision || "unavailable"}/#{hash}"

    id
    |> Evidence.source(project, field, content, false)
    |> Map.merge(%{"run_id" => nil, "revision" => revision, "content" => content || ""})
    |> Map.merge(metadata)
  end
end
