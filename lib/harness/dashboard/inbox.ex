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
  @list_timeout_ms 5_000

  @typedoc "Current Inbox projection, including named roadmap source errors."
  @type snapshot :: %{rows: [map()], coverage_errors: [{String.t(), term()}]}

  @doc "Loads current facts without fetching Git or reading an activity log."
  @spec load() :: {:ok, snapshot()} | {:error, term()}
  def load do
    case Application.get_env(:harness, :inbox_facts) do
      fun when is_function(fun, 0) -> with {:ok, facts} <- fun.(), do: {:ok, snapshot(facts)}
      nil -> load_current()
    end
  end

  @spec load_current() :: {:ok, snapshot()} | {:error, term()}
  defp load_current do
    projects = ProjectRegistry.list()

    with {:ok, records} <- ResultStore.list_run_records() do
      {tasks, coverage_errors} = tasks(projects)

      {:ok,
       snapshot(%{
         projects: projects,
         tasks: tasks,
         coverage_errors: coverage_errors,
         records: records,
         live_runs: Enum.map(StatusView.live_runs(), & &1.status),
         pending: PendingDispatch.list(),
         queued_tasks: Map.new(projects, &{&1.name, Harness.Oban.unfinished_run_task_ids(&1)}),
         landing_branches: Map.new(projects, &{&1.name, Harness.Oban.tracked_landing_branches(&1)})
       })}
    end
  end

  @spec snapshot(map()) :: snapshot()
  defp snapshot(facts) do
    %{
      rows: compose(facts),
      coverage_errors: facts |> Map.get(:coverage_errors, []) |> Enum.sort_by(&elem(&1, 0))
    }
  end

  # A missing, unreadable or timed-out rmap for one project must not hide
  # fleet-wide pending approvals or held runs, and must not look like a
  # readable empty roadmap. Recovery/land rows for that project stay off
  # the board until its task list is readable again.
  @spec tasks([Harness.Project.t()]) :: {map(), [{String.t(), term()}]}
  defp tasks(projects) do
    listed =
      projects
      |> Task.async_stream(&list_tasks/1, timeout: list_timeout_ms(), on_timeout: :kill_task)
      |> Enum.zip(projects)

    {task_map, errors} =
      Enum.reduce(listed, {%{}, []}, fn
        {{:ok, {:ok, tasks}}, project}, {acc, errors} when is_list(tasks) ->
          {Map.put(acc, project.name, tasks), errors}

        {failure, project}, {acc, errors} ->
          {acc, [{project.name, stream_reason(failure)} | errors]}
      end)

    {task_map, Enum.reverse(errors)}
  end

  @spec list_tasks(Harness.Project.t()) :: {:ok, [map()]} | {:error, term()}
  defp list_tasks(project) do
    case Application.get_env(:harness, :roadmap_list) do
      fun when is_function(fun, 1) -> fun.(project)
      _other -> Roadmap.list(project.name)
    end
  end

  @spec list_timeout_ms() :: pos_integer()
  defp list_timeout_ms, do: Application.get_env(:harness, :inbox_roadmap_timeout_ms, @list_timeout_ms)

  @spec stream_reason(term()) :: term()
  defp stream_reason({:ok, {:error, reason}}), do: reason
  defp stream_reason({:ok, reason}), do: reason
  defp stream_reason({:exit, :kill}), do: :timeout
  defp stream_reason({:exit, reason}), do: reason
  defp stream_reason(reason), do: reason

  @doc "Operator-facing named source error for an unreadable project roadmap."
  @spec format_coverage_error({String.t(), term()}) :: String.t()
  def format_coverage_error({project, reason}) do
    "#{project}: roadmap unavailable (#{format_reason(reason)})"
  end

  @spec format_reason(term()) :: String.t()
  defp format_reason(:roadmap_not_found), do: "no local roadmap"
  defp format_reason(:timeout), do: "timeout"
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)

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
          status = card.status

          [
            row(card.project_name, card.task_id, card.run_id, nil, actions, %{
              title: card.title,
              state: card.run_state,
              reason: status && status.reason,
              hold_reason: status && status.hold_reason
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
  defp available?(action, %{status: status} = card, facts)
       when action in [:resume_failed, :rereview] and is_map(status) do
    card.run_state == :failed and is_integer(status.agent_diff_size) and
      status.landed_sha in [nil, ""] and not match?([_, _ | _], status.task_ids) and
      card.task_id not in Map.get(facts.queued_tasks, card.project_name, [])
  end

  defp available?(action, _card, _facts) when action in [:resume_failed, :rereview], do: false

  defp available?(action, card, facts) when action in [:land, :reland] do
    case Enum.find(facts.projects, &(&1.name == card.project_name)) do
      %{target_branch: branch} when is_binary(branch) and branch != "" ->
        "harness/#{card.run_id}" not in Map.get(facts.landing_branches, card.project_name, []) and
          card.task_id not in Map.get(facts.queued_tasks, card.project_name, [])

      _missing ->
        false
    end
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
    case :global.trans({{__MODULE__, row.project, row.task_id}, self()}, fn -> claim(row, action) end) do
      :aborted -> {:error, :busy}
      result -> result
    end
  end

  @spec claim(map(), String.t()) :: {:ok, map()} | {:error, term()}
  defp claim(row, action) do
    with {:ok, %{rows: rows}} <- load(),
         current when not is_nil(current) <- Enum.find(rows, &(&1.id == row.id)),
         name when not is_nil(name) <- Enum.find(current.actions, &(Atom.to_string(&1) == action)) do
      dispatch(name, current)
    else
      nil -> {:error, :stale_action}
      {:error, _reason} = error -> error
    end
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
