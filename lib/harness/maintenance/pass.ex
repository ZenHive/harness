defmodule Harness.Maintenance.Pass do
  @moduledoc "A maintenance pass retains discovery before recoverable publication."

  alias Harness.Git
  alias Harness.Insights.Attempt
  alias Harness.Insights.Selection
  alias Harness.Maintenance
  alias Harness.Maintenance.Advisories
  alias Harness.Maintenance.Agent
  alias Harness.Maintenance.Publication
  alias Harness.Maintenance.Store
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.Worktree

  @doc "Runs against a fresh isolated target checkout with prior evidence."
  @spec run(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def run(name, id, config) do
    config = Map.put(config, "deadline", System.monotonic_time(:millisecond) + config["deadline_seconds"] * 1000)

    pass =
      Store.get("pass/" <> id) ||
        %{
          "id" => id,
          "project" => name,
          "at" => DateTime.to_iso8601(DateTime.utc_now()),
          "agent" => config["agent"],
          "model" => config["model"],
          "state" => "running",
          "committed" => false
        }

    config = Map.merge(config, Map.take(pass, ["agent", "model"]))

    pass =
      pass
      |> Map.delete("error")
      |> Map.merge(%{
        "state" => "running",
        "attempted_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "owner" => Attempt.owner(),
        "expires_at" => DateTime.utc_now() |> DateTime.shift(second: config["deadline_seconds"]) |> DateTime.to_iso8601()
      })

    with true <- pass["project"] == name || {:error, :pass_project_mismatch},
         :ok <- save(pass),
         {:ok, project} <- ProjectRegistry.lookup(name),
         {:ok, repo} <- Project.ensure_local_repo(project),
         target when is_binary(target) <- project.target_branch,
         {:ok, _} <- Git.run(["fetch", "origin", "refs/heads/#{target}:refs/remotes/origin/#{target}"], repo),
         {:ok, tree} <- Worktree.checkout_existing(repo, "origin/" <> target) do
      try do
        execute(project, tree.path, pass, config)
      after
        Worktree.remove(tree)
      end
    else
      {:error, reason} when is_atom(reason) -> fail(pass, reason)
      _ -> fail(pass, :source_unavailable)
    end
  rescue
    _ -> fail(%{"id" => id, "project" => name, "at" => DateTime.to_iso8601(DateTime.utc_now())}, :sweep_failed)
  end

  @spec execute(Project.t(), String.t(), map(), map()) :: :ok | {:error, term()}
  defp execute(project, path, pass, config) do
    with :ok <- Selection.validate(config),
         {:ok, sha} <- Git.run(["rev-parse", "HEAD"], path),
         {:ok, context} <- evidence(project, path),
         {:ok, pass} <- discover(path, Map.put_new(pass, "source_revision", String.trim(sha)), context, config),
         :ok <- save(pass),
         :ok <- retain(pass, "discovery"),
         {:ok, response} <- Publication.publish(project, pass, context, config) do
      state =
        cond do
          response["partial_evidence"] or context["evidence_gaps"] != [] -> "partial_evidence"
          response["findings"] == [] -> "no_findings"
          true -> "successful"
        end

      pass =
        Map.merge(pass, %{
          "state" => state,
          "committed" => true,
          "rationale" => response["rationale"],
          "findings" => response["findings"]
        })

      with :ok <- retain(pass, "publication"), do: save(pass)
    else
      {:error, reason} -> fail(pass, reason)
    end
  end

  @spec evidence(Project.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defp evidence(project, path) do
    with {:ok, raw} <- Publication.snapshot(project),
         {:ok, runs} <- Harness.ResultStore.list_run_records(project_name: project.name, limit: 100),
         {:ok, routing} <- Harness.Routing.brief() do
      previous = all_findings(project.name, 0, [])
      dependency = Harness.DepFreshness.fetch_snapshot(project.name)
      suite = Harness.SuiteHealthStore.fetch_result(project.name)
      advisories = Advisories.read(path)
      gaps = []
      gaps = if match?({:error, _}, dependency), do: ["dependency_freshness" | gaps], else: gaps
      gaps = if match?({:error, _}, suite), do: ["suite_health" | gaps], else: gaps
      gaps = if advisories["state"] == "unavailable", do: ["private_advisories" | gaps], else: gaps

      {:ok,
       %{
         "mode" => "discovery",
         "project" => project.name,
         "delivery_history_truncated" => Enum.count_until(runs, 100) == 100,
         "roadmap" => raw,
         "previous_findings" => previous,
         "dependency_freshness" => inspect(dependency, limit: :infinity),
         "suite_health" => inspect(suite, limit: :infinity),
         "delivery_evidence" => inspect(runs, limit: :infinity),
         "routing" => inspect(routing, limit: :infinity),
         "check_command" => project.check_command,
         "landing_policy" => to_string(project.landing_policy),
         "private_advisories" => advisories,
         "evidence_gaps" => gaps,
         "available_slots" => 3
       }}
    end
  end

  @spec all_findings(String.t(), non_neg_integer(), [map()]) :: [map()]
  defp all_findings(name, offset, acc) do
    page = Store.list("finding/" <> name, offset, 100)
    if Enum.count_until(page, 100) < 100, do: acc ++ page, else: all_findings(name, offset + 100, acc ++ page)
  end

  @spec discover(String.t(), map(), map(), map()) :: {:ok, map()} | {:error, term()}
  defp discover(path, pass, context, config) do
    if pass["findings"] do
      {:ok, pass}
    else
      agent = Application.get_env(:harness, :maintenance_agent, Agent)

      with {:ok, response} <- agent.assess(path, context, config),
           :ok <- Publication.validate(response) do
        previous = Map.new(context["previous_findings"], &{&1["id"], &1})

        findings = Enum.map(response["findings"], &identify(&1, previous, project_name(context)))

        {:ok,
         pass
         |> Map.put("findings", findings)
         |> Map.put("rationale", response["rationale"])
         |> Map.put("partial_evidence", response["partial_evidence"])}
      end
    end
  end

  @spec project_name(map()) :: String.t()
  defp project_name(context), do: context["project"]

  @spec identify(map(), map(), String.t()) :: map()
  defp identify(finding, previous, project) do
    prior = previous[finding["id"]] || %{}
    id = prior["id"] || Ecto.UUID.generate()

    Map.merge(finding, %{
      "id" => id,
      "publication_id" => prior["publication_id"] || Publication.identity(project, id),
      "task_id" => prior["task_id"]
    })
  end

  @spec retain(map(), String.t()) :: :ok | {:error, term()}
  defp retain(pass, stage) do
    Store.put_many(Enum.flat_map(pass["findings"], &assessment_documents(&1, pass, stage)))
  end

  @spec assessment_documents(map(), map(), String.t()) :: [tuple()]
  defp assessment_documents(finding, pass, stage) do
    revision = "revision/" <> finding["id"] <> "/" <> pass["id"] <> "/" <> stage

    if stage == "discovery" and Store.get(revision) do
      []
    else
      finding =
        finding
        |> Map.merge(Map.take(pass, ~w(project source_revision agent model at)))
        |> Map.put("assessment_stage", stage)
        |> Map.put("assessment_at", DateTime.to_iso8601(DateTime.utc_now()))

      [
        {"finding/" <> finding["id"], "finding/" <> pass["project"], finding},
        {revision, "revision/" <> finding["id"], finding}
      ]
    end
  end

  @spec save(map()) :: :ok | {:error, term()}
  defp save(pass) do
    with :ok <- Store.put_many([{"pass/" <> pass["id"], "pass", pass}]),
         do: Maintenance.progress(pass["project"], Map.delete(pass, "findings"))
  end

  @spec fail(map(), term()) :: {:error, term()}
  defp fail(pass, reason) do
    # Provider/tool output may contain private advisory details. Persist only a bounded error code.
    code = if is_atom(reason), do: Atom.to_string(reason), else: "publication_failed"
    save(Map.merge(Store.get("pass/" <> pass["id"]) || pass, %{"state" => "failed", "error" => code}))
    {:error, reason}
  end
end
