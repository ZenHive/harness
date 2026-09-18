defmodule Harness.Dispatch.Decision do
  @moduledoc "Validates explicit dispatch selections and prepares their execution without choosing recovery policy."

  alias Harness.AgentRegistry
  alias Harness.Dispatch
  alias Harness.Dispatch.Attempts
  alias Harness.Git
  alias Harness.ModelAvailability
  alias Harness.Project
  alias Harness.ResultStore
  alias Harness.Roadmap.Item

  @doc "Captures a planner selection against the exact history and task it saw."
  @spec capture(Project.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def capture(%Project{} = project, task, entry) do
    entry = Map.new(entry, fn {key, value} -> {to_string(key), value} end)
    history = Map.fetch!(task, "attempts")
    action = entry["action"] || if(history == [], do: "fresh")

    with :ok <- shape(action, entry, history),
         {:ok, selection} <- source_selection(action, entry, history) do
      {:ok,
       Map.merge(selection, %{
         "action" => action,
         "source_run_id" => entry["source_run_id"],
         "project_name" => project.name,
         "task_id" => to_string(task["id"]),
         "task_fingerprint" => task["task_fingerprint"],
         "agent" => entry["adapter"],
         "model" => entry["model"],
         "reason" => entry["reason"],
         "history_run_ids" => Enum.map(history, & &1["run_id"])
       })}
    end
  end

  @doc "Captures an explicit public recovery request using the same planner contract."
  @spec recovery(Project.t(), Item.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def recovery(project, item, action, source) do
    with {:ok, [task]} <- Attempts.attach(project, [%{"id" => item.id}]) do
      capture(project, Map.put(task, "task_fingerprint", item.fingerprint), %{
        action: action,
        source_run_id: source,
        adapter: to_string(item.agent),
        model: item.model || Harness.Config.agent_model(item.agent),
        reason: "Operator requested #{action} of #{source}"
      })
    end
  end

  @doc "Revalidates a queued decision before any run starts and supplies pinned run options."
  @spec prepare(Project.t(), Item.t(), module(), map()) :: {:ok, Item.t(), keyword()} | {:error, term()}
  def prepare(%Project{} = project, %Item{} = item, adapter, decision) when is_map(decision) do
    with :ok <- shape(decision["action"], decision, decision["history_run_ids"] || []),
         :ok <- identity(project, item, decision),
         :ok <- routing(adapter, decision),
         {:ok, tasks} <- Attempts.attach(project, [%{"id" => item.id}]),
         :ok <- history_unchanged(hd(tasks)["attempts"], decision),
         :ok <- not_landed(hd(tasks)["attempts"], item.fingerprint),
         :ok <- not_live(project, item),
         {:ok, prepared, opts} <- execution(project, item, decision) do
      {:ok, prepared, Keyword.put(opts, :dispatch_decision, Map.put(decision, "selected_sha", opts[:base_ref]))}
    else
      {:error, reason} -> {:error, {:stale_dispatch_decision, reason}}
    end
  end

  def prepare(_project, _item, _adapter, _decision), do: {:error, {:stale_dispatch_decision, :invalid_decision}}

  @spec shape(term(), map(), [map()]) :: :ok | {:error, term()}
  defp shape(action, entry, history) do
    cond do
      action not in ["fresh", "resume", "rereview"] -> {:error, :explicit_action_required}
      action == "fresh" and entry["source_run_id"] != nil -> {:error, :fresh_with_source}
      history != [] or Map.has_key?(entry, "action") -> required_fields(entry)
      true -> :ok
    end
  end

  @spec required_fields(map()) :: :ok | {:error, term()}
  defp required_fields(entry) do
    cond do
      not nonempty?(entry["reason"]) -> {:error, :reason_required}
      not nonempty?(entry["model"]) -> {:error, :model_required}
      true -> :ok
    end
  end

  @spec source_selection(String.t(), map(), [map()]) :: {:ok, map()} | {:error, term()}
  defp source_selection("fresh", _entry, _history), do: {:ok, %{}}

  defp source_selection(_action, entry, history) do
    case Enum.find(history, &(&1["run_id"] == entry["source_run_id"])) do
      %{"git" => %{"selected_sha" => sha, "on_origin" => false}, "landed_sha" => nil} = attempt ->
        if attempt["task_ids"] == [attempt["task_id"]],
          do: {:ok, %{"selected_sha" => sha}},
          else: {:error, :coalesced_recovery_unsupported}

      nil ->
        {:error, :invalid_source_run}

      _other ->
        {:error, :source_unavailable_or_landed}
    end
  end

  @spec identity(Project.t(), Item.t(), map()) :: :ok | {:error, term()}
  defp identity(project, item, decision) do
    cond do
      decision["project_name"] != project.name -> {:error, :project_changed}
      decision["task_id"] != item.id -> {:error, :task_changed}
      not nonempty?(item.fingerprint) -> {:error, :missing_task_fingerprint}
      decision["task_fingerprint"] != item.fingerprint -> {:error, :task_content_changed}
      match?([_, _ | _], item.task_ids) -> {:error, :coalesced_recovery_unsupported}
      true -> :ok
    end
  end

  @spec routing(module(), map()) :: :ok | {:error, term()}
  defp routing(adapter, decision) do
    with {:ok, agent} <- AgentRegistry.agent_for_module(adapter),
         true <- to_string(agent) == decision["agent"],
         {:ok, ^adapter} <- AgentRegistry.select(adapter),
         true <- ModelAvailability.available?(agent, decision["model"]) do
      :ok
    else
      _other -> {:error, :routing_unavailable}
    end
  end

  @spec history_unchanged([map()], map()) :: :ok | {:error, term()}
  defp history_unchanged(attempts, decision) do
    if Enum.sort(Enum.map(attempts, & &1["run_id"])) == Enum.sort(decision["history_run_ids"] || []) do
      :ok
    else
      {:error, :attempt_history_changed}
    end
  end

  @spec not_landed([map()], String.t()) :: :ok | {:error, term()}
  defp not_landed(attempts, fingerprint) do
    if Enum.any?(attempts, fn attempt ->
         attempt["task_fingerprint"] == fingerprint and
           (attempt["landed_sha"] != nil or committed_changes_on_origin?(attempt))
       end), do: {:error, :work_already_landed}, else: :ok
  end

  @spec committed_changes_on_origin?(map()) :: boolean()
  defp committed_changes_on_origin?(attempt) do
    get_in(attempt, ["git", "on_origin"]) == true and
      Enum.any?([attempt["agent_diff_size"], attempt["reviewer_diff_size"]], &(is_integer(&1) and &1 > 0))
  end

  @spec not_live(Project.t(), Item.t()) :: :ok | {:error, term()}
  defp not_live(project, item) do
    live =
      Enum.any?(Harness.Run.Supervisor.list_runs(), fn id ->
        case Harness.Run.status(id) do
          {:ok, status} ->
            status.project_name == project.name and status.task_id == item.id and
              status.state not in [:done, :failed]

          {:error, _reason} ->
            false
        end
      end)

    if live, do: {:error, :run_already_live}, else: :ok
  end

  @spec execution(Project.t(), Item.t(), map()) :: {:ok, Item.t(), keyword()} | {:error, term()}
  defp execution(project, item, %{"action" => "fresh"}) do
    with {:ok, repo} <- Project.local_repo_path(project),
         :ok <- Git.fetch_origin(repo),
         {:ok, output} <-
           Git.run(["rev-parse", "--verify", "refs/remotes/origin/#{project.target_branch}^{commit}"], repo) do
      {:ok, item, [base_ref: String.trim(output)]}
    end
  end

  defp execution(project, item, %{"action" => action, "source_run_id" => source, "selected_sha" => sha})
       when action in ["resume", "rereview"] do
    with {:ok, record} <- ResultStore.fetch_run_record(source),
         true <- record.project_name == project.name and record.task_id == item.id,
         true <- record.task_fingerprint == item.fingerprint,
         true <- record.landed_sha == nil and record.state in [:done, :failed],
         true <- Attempts.membership(record) == [item.id],
         {:ok, %{"selected_sha" => ^sha, "on_origin" => false}} <- Attempts.selection(project, source) do
      opts = [base_ref: sha, review_only?: action == "rereview", review_only_agent_diff_size: record.agent_diff_size]
      {:ok, Dispatch.resume_item(item, record), opts}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :source_changed_or_landed}
    end
  end

  defp execution(_project, _item, _decision), do: {:error, :invalid_decision}

  @spec nonempty?(term()) :: boolean()
  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""
end
