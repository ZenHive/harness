defmodule Harness.Dashboard.Inbox do
  @moduledoc "Current operator actions projected from approvals, runs, roadmaps and unfinished jobs."

  alias Harness.Cron.PendingDispatch
  alias Harness.Dashboard.TaskBoard
  alias Harness.Dispatch
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.Roadmap
  alias Harness.StatusView

  @actions [:resume_failed, :rereview, :land, :reland]

  @doc "Loads current facts without fetching Git or reading an activity log."
  @spec load() :: {:ok, [map()]} | {:error, term()}
  def load do
    case Application.get_env(:harness, :inbox_facts) do
      fun when is_function(fun, 0) -> with {:ok, facts} <- fun.(), do: {:ok, compose(facts)}
      nil -> load_current()
    end
  end

  @spec load_current() :: {:ok, [map()]} | {:error, term()}
  defp load_current do
    projects = ProjectRegistry.list()

    with {:ok, records} <- ResultStore.list_run_records(),
         {:ok, tasks} <- tasks(projects) do
      {:ok,
       compose(%{
         projects: projects,
         tasks: tasks,
         records: records,
         live_runs: Enum.map(StatusView.live_runs(), & &1.status),
         pending: PendingDispatch.list(),
         queued_tasks: Map.new(projects, &{&1.name, Harness.Oban.unfinished_run_task_ids(&1)}),
         landing_branches: Map.new(projects, &{&1.name, Harness.Oban.tracked_landing_branches(&1)})
       })}
    end
  end

  @spec tasks([Harness.Project.t()]) :: {:ok, map()} | {:error, term()}
  defp tasks(projects) do
    projects
    |> Task.async_stream(fn project -> {project.name, Roadmap.list(project.name)} end,
      timeout: 5_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({:ok, %{}}, fn
      {:ok, {name, {:ok, tasks}}}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, name, tasks)}}
      failure, _acc -> {:halt, {:error, {:roadmap_unavailable, failure}}}
    end)
  end

  @doc "One unresolved row per approval or selected run attempt; action alternatives do not inflate counts."
  @spec compose(map()) :: [map()]
  def compose(facts) do
    cards =
      TaskBoard.compose(
        projects: facts.projects,
        tasks: facts.tasks,
        live_runs: facts.live_runs,
        records: facts.records,
        landable_projects: TaskBoard.landable_project_names(facts.projects)
      )

    runs =
      cards
      |> Map.values()
      |> List.flatten()
      |> Enum.flat_map(fn card ->
        actions = Enum.filter(card.actions, &(&1 in @actions and available?(&1, card, facts)))

        if actions == [] do
          []
        else
          [
            row(card.project_name, card.task_id, card.run_id, nil, actions, %{
              title: card.title,
              state: card.run_state,
              reason: card.status.reason,
              hold_reason: card.status.hold_reason
            })
          ]
        end
      end)
      |> Enum.uniq_by(& &1.id)

    held =
      for status <- facts.live_runs, status.state == :held do
        row(status.project_name, status.task_id, status.run_id, nil, [:resume], %{
          title: nil,
          state: :held,
          reason: status.reason,
          hold_reason: status.hold_reason
        })
      end

    approvals =
      Enum.map(facts.pending, fn pending ->
        row(pending.project_name, pending.task_id, nil, pending, [:approve], %{
          parked_at: pending.parked_at,
          adapter: pending.adapter,
          decision: pending.opts
        })
      end)

    Enum.sort_by(approvals ++ held ++ runs, &{&1.project, &1.task_id, &1.id})
  end

  @spec available?(atom(), map(), map()) :: boolean()
  defp available?(action, card, facts) when action in [:resume_failed, :rereview] do
    card.run_state == :failed and is_integer(card.status.agent_diff_size) and
      card.status.landed_sha in [nil, ""] and not match?([_, _ | _], card.status.task_ids) and
      card.task_id not in Map.get(facts.queued_tasks, card.project_name, [])
  end

  defp available?(action, card, facts) when action in [:land, :reland] do
    project = Enum.find(facts.projects, &(&1.name == card.project_name))

    is_binary(project.target_branch) and project.target_branch != "" and
      "harness/#{card.run_id}" not in Map.get(facts.landing_branches, card.project_name, []) and
      card.task_id not in Map.get(facts.queued_tasks, card.project_name, [])
  end

  @spec row(String.t(), String.t(), String.t() | nil, map() | nil, [atom()], map()) :: map()
  defp row(project, task_id, run_id, pending, actions, context) do
    identity = {project, task_id, run_id, pending && {pending.id, pending.parked_at}, actions}
    id = identity |> :erlang.term_to_binary() |> then(&:crypto.hash(:sha256, &1)) |> Base.url_encode64(padding: false)
    %{id: id, project: project, task_id: task_id, run_id: run_id, pending: pending, actions: actions, context: context}
  end

  @doc "Revalidates the exact displayed row before invoking the guarded Dispatch facade."
  @spec perform(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def perform(row, action) do
    # Serialize Inbox submissions for the same task, including submissions from other tabs.
    :global.trans({{__MODULE__, row.project, row.task_id}, self()}, fn ->
      with {:ok, rows} <- load(),
           current when not is_nil(current) <- Enum.find(rows, &(&1.id == row.id)),
           name when not is_nil(name) <- Enum.find(current.actions, &(Atom.to_string(&1) == action)) do
        dispatch(name, current)
      else
        nil -> {:error, :stale_action}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc false
  @spec dispatch(atom(), map()) :: {:ok, map()} | {:error, term()}
  def dispatch(action, row) do
    case Application.get_env(:harness, :inbox_action) do
      fun when is_function(fun, 2) -> fun.(action, row)
      nil -> invoke(action, row)
    end
  end

  @spec invoke(atom(), map()) :: {:ok, map()} | {:error, term()}
  defp invoke(:approve, row), do: Dispatch.approve(row.pending.id, row.pending.parked_at)
  defp invoke(:resume, row), do: Dispatch.resume(row.run_id)
  defp invoke(:resume_failed, row), do: verify_recovery(Dispatch.resume_failed(row.run_id), row, "resume")
  defp invoke(:rereview, row), do: verify_recovery(Dispatch.rereview(row.run_id), row, "rereview")
  defp invoke(action, row) when action in [:land, :reland], do: Dispatch.reland(row.run_id)

  @doc false
  @spec verify_recovery({:ok, map()} | {:error, term()}, map(), String.t()) :: {:ok, map()} | {:error, term()}
  def verify_recovery({:error, _reason} = error, _row, _action), do: error

  def verify_recovery({:ok, result}, row, action) do
    with {:ok, status} <- Dispatch.status(result.run_id),
         %{dispatch_decision: %{"source_run_id" => source, "action" => ^action}} <- status,
         true <- source == row.run_id and status.project_name == row.project and status.task_id == row.task_id do
      {:ok, result}
    else
      _other -> {:error, {:recovery_receipt_mismatch, result.run_id}}
    end
  end

  @doc "Operator-facing operation name."
  @spec label(atom()) :: String.t()
  def label(:approve), do: "Approve"
  def label(:resume), do: "Resume"
  def label(:resume_failed), do: "Resume Failed"
  def label(:rereview), do: "Rereview"
  def label(:land), do: "Land"
  def label(:reland), do: "Reland"
end
