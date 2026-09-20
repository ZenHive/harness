defmodule Harness.Maintenance.Publication do
  @moduledoc "Recoverable maintenance task creation through the durable roadmap boundary."

  import Ecto.Query

  alias Harness.Git
  alias Harness.Maintenance
  alias Harness.Maintenance.Agent
  alias Harness.Maintenance.Command
  alias Harness.Maintenance.Store
  alias Harness.Project
  alias Harness.Repo
  alias Harness.Roadmap.Durable
  alias Harness.Worktree

  @doc "Reads and validates the entire current roadmap through its owning CLI."
  # root is the caller-owned isolated git checkout, never a request path.
  # sobelow_skip ["Traversal.FileModule"]
  @spec read(String.t()) :: {:ok, [map()], String.t()} | {:error, atom()}
  def read(root) do
    path = Path.join(root, "roadmap/tasks.toml")

    with true <- File.regular?(Path.join(root, "ROADMAP.md")),
         {:ok, raw} <- File.read(path),
         {output, 0} <- System.cmd("rmap", ["list", "--json", "--tasks-path", path], cd: root, stderr_to_stdout: true),
         {:ok, %{"task" => tasks}} when is_list(tasks) <- Jason.decode(output) do
      {:ok, tasks, raw}
    else
      _ -> {:error, :roadmap_unavailable}
    end
  end

  @doc "Reads the roadmap's own current target without using or modifying the operator checkout."
  @spec snapshot(Project.t()) :: {:ok, String.t()} | {:error, term()}
  def snapshot(project) do
    with {:ok, root, target, relative} <- destination(project),
         {:ok, _} <- Git.run(["fetch", "origin", "refs/heads/#{target}:refs/remotes/origin/#{target}"], root),
         {:ok, tree} <- Worktree.checkout_existing(root, "origin/" <> target) do
      try do
        case read(Path.join(tree.path, relative)) do
          {:ok, _, raw} -> {:ok, raw}
          error -> error
        end
      after
        Worktree.remove(tree)
      end
    end
  end

  @doc "Reconciles the fresh remote roadmap on every retry, including a push-before-checkpoint crash."
  @spec publish(Project.t(), map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def publish(project, pass, context, settings) do
    with {:ok, root, target, relative} <- destination(project) do
      case Durable.commit(root, target,
             message: "maintenance: publish assessed work",
             apply: fn checkout -> reconcile(Path.join(checkout, relative), pass, context, settings) end
           ) do
        {:ok, output} -> Jason.decode(output)
        error -> error
      end
    end
  end

  @spec destination(Project.t()) :: {:ok, String.t(), String.t(), String.t()} | {:error, atom()}
  defp destination(project) do
    with {:ok, output} <- Git.run(["rev-parse", "--show-toplevel"], project.roadmap_path),
         {:ok, prefix} <- Git.run(["rev-parse", "--show-prefix"], project.roadmap_path) do
      root = String.trim(output)
      target = project.roadmap_target_branch || source_target(project, root)

      if is_binary(target) and target != "",
        do: {:ok, root, target, String.trim(prefix)},
        else: {:error, :roadmap_target_required}
    else
      _ ->
        {:error, :roadmap_unavailable}
    end
  end

  @spec source_target(Project.t(), String.t()) :: String.t() | nil
  defp source_target(project, root) do
    case Git.run(["rev-parse", "--show-toplevel"], Project.repo_path(project)) do
      {:ok, source} -> if String.trim(source) == root, do: project.target_branch
      _ -> nil
    end
  end

  @spec reconcile(String.t(), map(), map(), map()) :: {:ok, String.t()} | {:error, term()}
  defp reconcile(root, pass, context, settings) do
    with true <- Maintenance.settings(pass["project"])["enabled"] || {:error, :disabled},
         true <- System.monotonic_time(:millisecond) < settings["deadline"] || {:error, :deadline_exceeded},
         {:ok, tasks, raw} <- read(root),
         :ok <- history_known(tasks, context["previous_findings"]),
         :ok <- identities_known(root, tasks, pass["findings"]),
         {:ok, active} <- unfinished_count(tasks, pass["project"]) do
      recovered = Enum.filter(pass["findings"], fn f -> Enum.any?(tasks, &identity?(&1, f["publication_id"])) end)

      input =
        Map.merge(context, %{
          "mode" => "publication",
          "roadmap" => raw,
          "previous_findings" => pass["findings"],
          "available_slots" => max(3 - active, 0)
        })

      with {:ok, response} <- agent().assess(root, input, settings),
           :ok <- validate(response),
           :ok <- record_assessment(pass, response),
           true <- response["publication_safe"] || {:error, :publication_not_safe},
           {:ok, selected} <- selected(response, pass, recovered, 3 - active),
           :ok <- create(root, selected, pass["project"]) do
        {:ok, published, _} = read(root)

        links = publication_links(recovered ++ selected, published)

        findings = Enum.map(pass["findings"], &merge_assessment(&1, response, links))

        {:ok, Jason.encode!(Map.put(response, "findings", findings))}
      else
        {:error, _} = error -> error
      end
    end
  end

  @spec publication_links([map()], [map()]) :: map()
  defp publication_links(findings, published) do
    Map.new(findings, fn finding ->
      task = Enum.find(published, &identity?(&1, finding["publication_id"]))
      {finding["id"], task["id"]}
    end)
  end

  @spec merge_assessment(map(), map(), map()) :: map()
  defp merge_assessment(finding, response, links) do
    assessment = Enum.find(response["findings"], &(&1["id"] == finding["id"])) || finding

    finding
    |> Map.merge(Map.drop(assessment, ["id", "publication_id", "task_id"]))
    |> Map.put("task_id", links[finding["id"]] || finding["task_id"])
  end

  @spec record_assessment(map(), map()) :: :ok | {:error, term()}
  defp record_assessment(pass, response) do
    Store.put_many([
      {"pass/" <> pass["id"], "pass", Map.merge(pass, Map.take(response, ["rationale", "partial_evidence"]))}
    ])
  end

  @spec history_known([map()], [map()]) :: :ok | {:error, atom()}
  defp history_known(tasks, findings) do
    if Enum.all?(findings, fn f -> is_nil(f["task_id"]) or Enum.any?(tasks, &(&1["id"] == f["task_id"])) end),
      do: :ok,
      else: {:error, :publication_history_unknown}
  end

  @spec selected(map(), map(), [map()], integer()) :: {:ok, [map()]} | {:error, atom()}
  defp selected(response, pass, recovered, slots) do
    candidates = Enum.filter(response["findings"], &(&1["selected"] and not &1["blocked"]))
    known = Map.new(pass["findings"], &{&1["id"], &1})

    if Enum.all?(candidates, &Map.has_key?(known, &1["id"])) do
      candidates =
        candidates
        |> Enum.reject(fn f -> known[f["id"]]["task_id"] || Enum.any?(recovered, &(&1["id"] == f["id"])) end)
        |> Enum.map(&Map.merge(known[&1["id"]], Map.drop(&1, ["publication_id", "task_id"])))

      if length(candidates) <= max(slots, 0), do: {:ok, candidates}, else: {:error, :task_limit}
    else
      {:error, :unknown_finding}
    end
  end

  @doc "Creates a stable publication marker independent of rmap's numeric task allocation."
  @spec identity(String.t(), String.t()) :: String.t()
  def identity(project, id), do: "[harness-maintenance:" <> Base.url_encode64(project, padding: false) <> ":" <> id <> "]"

  @spec identity?(map(), String.t()) :: boolean()
  defp identity?(task, id), do: String.contains?(task["body"] || "", "\n" <> id <> "\n")

  @spec identities_known(String.t(), [map()], [map()]) :: :ok | {:error, atom()}
  defp identities_known(root, tasks, findings) do
    Enum.reduce_while(findings, :ok, fn finding, :ok ->
      case Enum.filter(tasks, &identity?(&1, finding["publication_id"])) do
        [_] -> {:cont, :ok}
        [] -> history_absent(root, finding["publication_id"])
        _ -> {:halt, {:error, :duplicate_publication_identity}}
      end
    end)
  end

  @spec history_absent(String.t(), String.t()) :: {:cont, :ok} | {:halt, {:error, atom()}}
  defp history_absent(root, id) do
    with {:ok, shallow} <- Git.run(["rev-parse", "--is-shallow-repository"], root),
         true <- String.trim(shallow) == "false",
         {:ok, history} <- Git.run(["log", "-1", "--format=%H", "-S", id, "--", "roadmap/tasks.toml"], root),
         true <- String.trim(history) == "" do
      {:cont, :ok}
    else
      _ -> {:halt, {:error, :publication_history_unknown}}
    end
  end

  @doc "Identifies maintenance publication identities belonging to one target repository."
  @spec maintenance_task?(map(), String.t()) :: boolean()
  def maintenance_task?(task, project) do
    String.contains?(task["body"] || "", "\n[harness-maintenance:" <> Base.url_encode64(project, padding: false) <> ":")
  end

  @doc "Counts unfinished roadmap tasks and live dispatches, including coalesced membership."
  @spec unfinished_count([map()], String.t()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def unfinished_count(tasks, project) do
    with {:ok, live} <- live_task_ids(project) do
      count = Enum.count(tasks, &(maintenance_task?(&1, project) and (&1["status"] != "done" or &1["id"] in live)))
      {:ok, count}
    end
  end

  @spec live_task_ids(String.t()) :: {:ok, [String.t()]} | {:error, atom()}
  defp live_task_ids(project) do
    if Store.persistent?() do
      query =
        from job in Oban.Job,
          where:
            job.worker == "Harness.Run.Worker" and
              job.state in ["available", "scheduled", "executing", "retryable"] and
              fragment("?->>'project_name' = ?", job.args, ^project),
          select: job.args

      ids = query |> Repo.all() |> Enum.flat_map(&[&1["item_id"] | Map.get(&1, "item_ids", [])])
      {:ok, ids}
    else
      {:ok, []}
    end
  rescue
    _ in [RuntimeError, DBConnection.ConnectionError, DBConnection.OwnershipError, Postgrex.Error] ->
      {:error, :execution_history_unavailable}
  end

  @doc "Validates transport structure only; the AI owns relevance and prioritization."
  @spec validate(term()) :: :ok | {:error, atom()}
  def validate(%{
        "findings" => findings,
        "partial_evidence" => partial,
        "publication_safe" => safe,
        "rationale" => rationale
      })
      when is_list(findings) and is_boolean(partial) and is_boolean(safe) and is_binary(rationale) do
    if Enum.count_until(findings, 51) <= 50 and
         Enum.all?(findings, fn f ->
           is_map(f) and
             Enum.all?(~w(title category evidence rationale improvement outcome), &is_binary(f[&1])) and
             is_boolean(f["blocked"]) and is_boolean(f["selected"])
         end), do: :ok, else: {:error, :invalid_findings}
  end

  def validate(_), do: {:error, :invalid_findings}

  @spec create(String.t(), [map()], String.t()) :: :ok | {:error, atom()}
  defp create(root, findings, project) do
    Enum.reduce_while(findings, :ok, fn f, :ok ->
      with {:ok, fragment} <- task_fragment(f),
           :ok <- insert(root, fragment <> "target_repo = " <> Jason.encode!(project) <> "\n", f["publication_id"]) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  @spec task_fragment(map()) :: {:ok, String.t()} | {:error, atom()}
  defp task_fragment(%{"task" => task, "publication_id" => id}) when is_map(task) do
    text = ~w(title body bundle assignee model)
    lists = ~w(files_to_modify touches acceptance_criteria out_of_scope)

    with true <- Enum.all?(text, &(is_binary(task[&1]) and task[&1] != "")),
         true <- Enum.all?(lists, &(is_list(task[&1]) and Enum.all?(task[&1], fn v -> is_binary(v) end))),
         true <- task["acceptance_criteria"] != [] and task["touches"] != [],
         true <- is_integer(task["phase"]),
         true <- Enum.all?(~w(d b u), &(task[&1] in 1..10)),
         {:ok, brief} <- Harness.Routing.brief(),
         true <- Enum.any?(brief.pairs, &(to_string(&1.agent) == task["assignee"] and &1.model == task["model"])) do
      task = Map.update!(task, "body", &(&1 <> "\n" <> id <> "\n"))
      fields = Enum.map_join(text ++ lists ++ ["phase"], "\n", &(&1 <> " = " <> Jason.encode!(task[&1])))

      {:ok,
       ~s([[task]]\nstatus = "pending"\nscores = { d = #{task["d"]}, b = #{task["b"]}, u = #{task["u"]} }\n) <>
         fields <> "\n"}
    else
      _ -> {:error, :invalid_task_contract}
    end
  end

  defp task_fragment(_), do: {:error, :invalid_task_contract}

  # Exclusive UUID file owned by this invocation; no caller-controlled path components.
  # sobelow_skip ["Traversal.FileModule"]
  @spec insert(String.t(), String.t(), String.t()) :: :ok | {:error, atom()}
  defp insert(root, fragment, id) do
    path = Path.join(System.tmp_dir!(), "maintenance-task-#{Ecto.UUID.generate()}")
    File.write!(path, fragment, [:exclusive])

    try do
      case write_task(root, path, fragment) do
        {_, 0} ->
          case read(root) do
            {:ok, tasks, _} -> if Enum.any?(tasks, &identity?(&1, id)), do: :ok, else: {:error, :task_not_created}
            error -> error
          end

        _ ->
          {:error, :task_creation_failed}
      end
    after
      File.rm(path)
    end
  end

  # The root is a fresh detached checkout; rmap validates and renders before any commit.
  # rmap new requires an existing task table, so an empty roadmap needs its first numeric row.
  # sobelow_skip ["Traversal.FileModule"]
  @spec write_task(String.t(), String.t(), String.t()) :: {String.t(), term()}
  defp write_task(root, path, fragment) do
    case read(root) do
      {:ok, [], _} ->
        date = Date.to_iso8601(Date.utc_today())

        fragment =
          String.replace_prefix(
            fragment,
            "[[task]]",
            "[[task]]\nid = \"1\"\ncreated_at = #{Jason.encode!(date)}\nscored_at = #{Jason.encode!(date)}"
          )

        File.write!(Path.join(root, "roadmap/tasks.toml"), "\n" <> fragment, [:append])

        case Command.run("rmap", ["validate"], cd: root, timeout: 30_000) do
          {_, 0} -> Command.run("rmap", ["render"], cd: root, timeout: 30_000)
          failure -> failure
        end

      {:ok, _, _} ->
        Command.run("/bin/sh", ["-c", ~s(exec rmap new --from-stdin < "$1"), "maintenance", path],
          cd: root,
          stderr_to_stdout: true,
          timeout: 30_000
        )

      _ ->
        {"", :roadmap_unavailable}
    end
  end

  @spec agent() :: module()
  defp agent, do: Application.get_env(:harness, :maintenance_agent, Agent)
end
