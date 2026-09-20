defmodule Harness.Dashboard.TaskBoard do
  @moduledoc """
  Composes the `/harness/roadmap` fleet board from current rmap, run, and
  landing facts.

  This is a **projection**, not a store. rmap remains authoritative for durable
  task status (`pending` / `blocked` / `done`). Live `Harness.Run.Status`
  snapshots and persisted `LogRecord`s supply execution and landing context.
  Nothing here writes a new status, scores urgency, or ranks health.

  ## Placement precedence

  Identity is `{project_name, task_id}`. Each kept rmap task occupies exactly
  one lane. Sources that disagree are resolved in this order:

  1. **rmap `done`** → Done. An older unlanded or failed attempt cannot complete
     a still-open task, and cannot pull a done task back into Landing.
  2. **rmap `blocked`** → Blocked. A live run on a blocked task stays a badge
     on that card; it does not move the card.
  3. **Non-terminal live run** (including `:held`) → Implementing or Reviewing.
     `:held` is never its own lane: the last entered non-held stage chooses
     the lane, and `held` is a badge.
  4. **rmap `in_progress`** with the selected attempt approved and unlanded →
     Landing. A live linger in `:done` with the same facts uses this lane too.
  5. **rmap `in_progress`** otherwise → Implementing (failed/held attempts are
     badges and action state on that card).
  6. **rmap `pending`** → Pending. Membership in the rmap ready set
     controls dispatch eligibility. Dependency labels compare rmap `depends_on`
     against that project’s done tasks; missing dependency data stays unknown.

  The **selected attempt** is the non-terminal live run when one exists,
  otherwise the newest live or persisted attempt for that identity (coalesced
  `task_ids` count). A persisted record wins for the same run id,
  retaining its landing witness. Multiple live attempts prefer non-terminal
  then newest start time, with run id as a stable tie-breaker. An older approved
  record never places a pending task in Done or Landing.
  """

  alias Harness.Project
  alias Harness.Run.LogRecord
  alias Harness.Run.Status
  alias Harness.TokenUsage

  @lanes [:pending, :implementing, :reviewing, :landing, :blocked, :done]
  @rmap_statuses ~w(pending in_progress blocked done)
  @done_limit 20
  @implementing_states [:dispatched, :running, :committing, :recovering]
  @terminal_states [:done, :failed]

  defmodule Card do
    @moduledoc """
    One board card: rmap identity plus the selected Harness attempt, if any.
    """

    @enforce_keys [:project_name, :task_id, :lane, :rmap_status]
    defstruct [
      :project_name,
      :task_id,
      :title,
      :assignee,
      :model,
      :lane,
      :rmap_status,
      :dependency,
      :run_id,
      :run_state,
      :status,
      :token_total,
      :landed_sha,
      :done_at,
      held?: false,
      failed?: false,
      actions: []
    ]

    @typedoc "Factual board action whose existing Dispatch/Lander guard can fire."
    @type action :: :dispatch | :hold | :resume | :resume_failed | :rereview | :land | :reland

    @typedoc "Pending dependency readiness from rmap task facts, when known."
    @type dependency :: :ready | :waiting | :unknown | nil

    @typedoc "A renderable task card."
    @type t :: %__MODULE__{
            project_name: String.t(),
            task_id: String.t(),
            title: String.t() | nil,
            assignee: String.t() | nil,
            model: String.t() | nil,
            lane: Harness.Dashboard.TaskBoard.lane(),
            rmap_status: String.t(),
            dependency: dependency(),
            run_id: String.t() | nil,
            run_state: Status.state() | nil,
            status: Status.t() | nil,
            token_total: non_neg_integer() | nil,
            landed_sha: String.t() | nil,
            done_at: String.t() | nil,
            held?: boolean(),
            failed?: boolean(),
            actions: [action()]
          }
  end

  @typedoc "Factual workflow lane on the roadmap board."
  @type lane :: :pending | :implementing | :reviewing | :landing | :blocked | :done

  @typedoc "Ready-set membership keyed by `{project_name, task_id}`."
  @type ready_ids :: MapSet.t({String.t(), String.t()})

  @typedoc "Project names where a first manual land can succeed."
  @type landable_projects :: MapSet.t(String.t())

  @typedoc "Inputs for `compose/1`."
  @type compose_opts :: [
          {:projects, [Project.t()]}
          | {:tasks, %{optional(String.t()) => [map()]}}
          | {:ready_ids, ready_ids()}
          | {:live_runs, [Status.t()]}
          | {:records, [LogRecord.t()]}
          | {:landable_projects, landable_projects()}
          | {:done_limit, pos_integer()}
        ]

  @doc "Lane ids in left-to-right board order."
  @spec lanes() :: [lane()]
  def lanes, do: @lanes

  @doc "Operator-facing lane title."
  @spec lane_label(lane()) :: String.t()
  def lane_label(:pending), do: "Pending"
  def lane_label(:implementing), do: "Implementing"
  def lane_label(:reviewing), do: "Reviewing"
  def lane_label(:landing), do: "Landing"
  def lane_label(:blocked), do: "Blocked"
  def lane_label(:done), do: "Done"

  @doc """
  Builds one card per kept rmap task, grouped into factual lanes.

  `superseded` and unknown rmap statuses are omitted. Done is bounded
  per project by `done_limit` (default 20), newest `done_at` first.
  """
  @spec compose(compose_opts()) :: %{lane() => [Card.t()]}
  def compose(opts) when is_list(opts) do
    projects = Keyword.get(opts, :projects, [])
    tasks_by_project = Keyword.get(opts, :tasks, %{})
    ready_ids = Keyword.get(opts, :ready_ids, MapSet.new())
    live_index = index_live(Keyword.get(opts, :live_runs, []))
    record_index = index_records(Keyword.get(opts, :records, []))
    landable = Keyword.get(opts, :landable_projects, MapSet.new())
    done_limit = Keyword.get(opts, :done_limit, @done_limit)

    projects
    |> Enum.flat_map(&project_cards(&1, tasks_by_project, ready_ids, live_index, record_index, landable))
    |> Enum.group_by(& &1.lane)
    |> bound_done(done_limit)
    |> fill_lanes()
  end

  @doc "Keeps cards for `project_name`, or every card when the filter is nil/blank."
  @spec filter_project(%{lane() => [Card.t()]}, String.t() | nil) :: %{lane() => [Card.t()]}
  def filter_project(lanes, project) when project in [nil, ""], do: lanes

  def filter_project(lanes, project_name) when is_binary(project_name) do
    Map.new(lanes, fn {lane, cards} ->
      {lane, Enum.filter(cards, &(&1.project_name == project_name))}
    end)
  end

  @doc "Manual-policy projects that have a `target_branch` — the first-land gate."
  @spec landable_project_names([Project.t()]) :: landable_projects()
  def landable_project_names(projects) do
    for %Project{name: name, landing_policy: :manual, target_branch: branch} <- projects,
        is_binary(branch) and branch != "",
        into: MapSet.new(),
        do: name
  end

  @spec project_cards(
          Project.t(),
          %{optional(String.t()) => [map()]},
          ready_ids(),
          map(),
          map(),
          landable_projects()
        ) :: [Card.t()]
  defp project_cards(project, tasks_by_project, ready_ids, live_index, record_index, landable) do
    tasks = Map.get(tasks_by_project, project.name, [])
    done_ids = tasks |> Enum.filter(&(&1["status"] == "done")) |> MapSet.new(&task_id/1)

    tasks
    |> Enum.filter(&keep_task?/1)
    |> Enum.map(&card_for(project.name, &1, ready_ids, live_index, record_index, landable, done_ids))
    |> Enum.sort_by(&{&1.project_name, numeric_task_key(&1.task_id), &1.task_id})
  end

  @spec keep_task?(map()) :: boolean()
  defp keep_task?(%{"status" => status}) when status in @rmap_statuses, do: true
  defp keep_task?(_task), do: false

  @spec card_for(String.t(), map(), ready_ids(), map(), map(), landable_projects(), MapSet.t()) :: Card.t()
  defp card_for(project_name, task, ready_ids, live_index, record_index, landable, done_ids) do
    task_id = task_id(task)
    identity = {project_name, task_id}
    rmap_status = task["status"]
    live = Map.get(live_index, identity)
    records = Map.get(record_index, identity, [])
    execution = execution_run(live)
    selected = selected_attempt(live, records)
    lane = lane_for(rmap_status, execution, selected)

    %Card{
      project_name: project_name,
      task_id: task_id,
      title: present(task["title"]),
      assignee: assignee(task, selected),
      model: model(task, selected),
      lane: lane,
      rmap_status: rmap_status,
      dependency: dependency(lane, task, done_ids),
      run_id: selected && selected.run_id,
      run_state: selected && selected.state,
      status: selected,
      token_total: token_total(records, selected),
      landed_sha: selected && present(selected.landed_sha),
      done_at: present(task["done_at"]),
      held?: held?(selected),
      failed?: selected != nil and selected.state == :failed,
      actions:
        actions(
          lane,
          execution,
          persisted_attempt(selected, records),
          rmap_status,
          project_name,
          landable,
          identity,
          ready_ids
        )
    }
  end

  @spec lane_for(String.t(), Status.t() | nil, Status.t() | nil) :: lane()
  defp lane_for("done", _execution, _selected), do: :done
  defp lane_for("blocked", _execution, _selected), do: :blocked
  defp lane_for(_rmap_status, %Status{} = execution, _selected), do: execution_lane(execution)
  defp lane_for("in_progress", _execution, selected), do: in_progress_lane(selected)
  defp lane_for(_rmap_status, _execution, _selected), do: :pending

  @spec execution_lane(Status.t()) :: lane()
  defp execution_lane(%Status{state: :reviewing}), do: :reviewing
  defp execution_lane(%Status{state: :held} = status), do: held_lane(status)
  defp execution_lane(%Status{}), do: :implementing

  @spec held_lane(Status.t()) :: lane()
  defp held_lane(%Status{state_entered_at: entered}) when is_map(entered) do
    case latest_stage(entered) do
      :reviewing -> :reviewing
      _other -> :implementing
    end
  end

  defp held_lane(_status), do: :implementing

  @spec in_progress_lane(Status.t() | nil) :: lane()
  defp in_progress_lane(selected) do
    if landing_attempt?(selected), do: :landing, else: :implementing
  end

  @spec landing_attempt?(Status.t() | nil) :: boolean()
  defp landing_attempt?(%Status{state: :done, review_verdict: :approve, landed_sha: sha}) when sha in [nil, ""], do: true

  defp landing_attempt?(_selected), do: false

  @spec execution_run(Status.t() | nil) :: Status.t() | nil
  defp execution_run(%Status{state: state} = status) when state not in @terminal_states, do: status
  defp execution_run(_status), do: nil

  @spec selected_attempt(Status.t() | nil, [LogRecord.t()]) :: Status.t() | nil
  defp selected_attempt(%Status{state: state} = live, _records) when state not in @terminal_states, do: live

  defp selected_attempt(live, records) do
    stored =
      case newest_record(records) do
        nil -> nil
        record -> Status.from_log_record(record)
      end

    case {live, stored} do
      {nil, stored} -> stored
      {live, nil} -> live
      {%Status{run_id: id}, %Status{run_id: id} = stored} -> stored
      {live, stored} -> Enum.max_by([live, stored], &record_recency/1)
    end
  end

  @spec persisted_attempt(Status.t() | nil, [LogRecord.t()]) :: Status.t() | nil
  defp persisted_attempt(nil, _records), do: nil

  defp persisted_attempt(selected, records) do
    if Enum.any?(records, &(&1.run_id == selected.run_id)), do: selected
  end

  @spec newest_record([LogRecord.t()]) :: LogRecord.t() | nil
  defp newest_record([]), do: nil
  defp newest_record(records), do: Enum.max_by(records, &record_recency/1)

  @spec record_recency(LogRecord.t() | Status.t()) :: {0 | 1, integer(), String.t()}
  defp record_recency(%{started_at: %DateTime{} = started, run_id: run_id}) do
    {1, DateTime.to_unix(started, :microsecond), run_id}
  end

  defp record_recency(%{run_id: run_id}), do: {0, 0, run_id}

  @spec dependency(lane(), map(), MapSet.t()) :: Card.dependency()
  defp dependency(:pending, %{"depends_on" => deps}, done_ids) when is_list(deps) do
    if Enum.all?(deps, &MapSet.member?(done_ids, to_string(&1))), do: :ready, else: :waiting
  end

  defp dependency(:pending, _task, _done_ids), do: :unknown
  defp dependency(_lane, _task, _done_ids), do: nil

  @spec actions(
          lane(),
          Status.t() | nil,
          Status.t() | nil,
          String.t(),
          String.t(),
          landable_projects(),
          {String.t(), String.t()},
          ready_ids()
        ) :: [Card.action()]
  defp actions(lane, execution, selected, rmap_status, project_name, landable, identity, ready_ids) do
    []
    |> maybe_action(:dispatch, dispatchable?(lane, identity, ready_ids))
    |> maybe_action(:hold, holdable?(execution))
    |> maybe_action(:resume, resumable_held?(execution))
    |> maybe_action(:resume_failed, rmap_status != "done" and resume_failed?(selected, execution))
    |> maybe_action(:rereview, rereviewable?(selected, execution, rmap_status))
    |> maybe_action(:land, landable?(selected, rmap_status, project_name, landable))
    |> maybe_action(:reland, relandable?(selected, rmap_status))
  end

  @spec maybe_action([Card.action()], Card.action(), boolean()) :: [Card.action()]
  defp maybe_action(actions, action, true), do: actions ++ [action]
  defp maybe_action(actions, _action, false), do: actions

  @spec dispatchable?(lane(), {String.t(), String.t()}, ready_ids()) :: boolean()
  defp dispatchable?(:pending, identity, ready_ids), do: MapSet.member?(ready_ids, identity)
  defp dispatchable?(_lane, _identity, _ready_ids), do: false

  @spec holdable?(Status.t() | nil) :: boolean()
  defp holdable?(%Status{state: :running}), do: true
  defp holdable?(_status), do: false

  @spec resumable_held?(Status.t() | nil) :: boolean()
  defp resumable_held?(%Status{state: :held}), do: true
  defp resumable_held?(_status), do: false

  @spec resume_failed?(Status.t() | nil, Status.t() | nil) :: boolean()
  defp resume_failed?(%Status{state: :failed} = selected, nil), do: recoverable_attempt?(selected)
  defp resume_failed?(_selected, _execution), do: false

  @spec rereviewable?(Status.t() | nil, Status.t() | nil, String.t()) :: boolean()
  defp rereviewable?(%Status{run_id: run_id} = selected, nil, rmap_status)
       when is_binary(run_id) and rmap_status != "done", do: recoverable_attempt?(selected)

  defp rereviewable?(_selected, _execution, _rmap_status), do: false

  @spec recoverable_attempt?(Status.t()) :: boolean()
  defp recoverable_attempt?(%Status{landed_sha: nil, task_id: task_id, task_ids: ids}) when is_list(ids) do
    Enum.all?(ids, &(&1 == task_id))
  end

  defp recoverable_attempt?(_selected), do: false

  @spec landable?(Status.t() | nil, String.t(), String.t(), landable_projects()) :: boolean()
  defp landable?(%Status{} = selected, rmap_status, project_name, landable) do
    landing_attempt?(selected) and rmap_status == "in_progress" and MapSet.member?(landable, project_name)
  end

  defp landable?(_selected, _rmap_status, _project_name, _landable), do: false

  @spec relandable?(Status.t() | nil, String.t()) :: boolean()
  defp relandable?(%Status{} = selected, "blocked"), do: landing_attempt?(selected)
  defp relandable?(_selected, _rmap_status), do: false

  @spec assignee(map(), Status.t() | nil) :: String.t() | nil
  defp assignee(_task, %Status{agent: agent}) when not is_nil(agent), do: Atom.to_string(agent)
  defp assignee(%{"assignee" => assignee}, _selected) when is_binary(assignee) and assignee != "", do: assignee
  defp assignee(_task, _selected), do: nil

  @spec model(map(), Status.t() | nil) :: String.t() | nil
  defp model(_task, %Status{model: model}) when is_binary(model) and model != "", do: model
  defp model(%{"model" => model}, _selected) when is_binary(model) and model != "", do: model
  defp model(_task, _selected), do: nil

  @spec token_total([LogRecord.t()], Status.t() | nil) :: non_neg_integer() | nil
  defp token_total(records, %Status{run_id: run_id}) do
    case Enum.find(records, &(&1.run_id == run_id)) do
      %LogRecord{token_usage: %TokenUsage{} = usage} -> measured_total(usage)
      _missing -> nil
    end
  end

  defp token_total(_records, _selected), do: nil

  @spec measured_total(TokenUsage.t()) :: non_neg_integer() | nil
  defp measured_total(%TokenUsage{total: total} = usage) do
    if TokenUsage.measured?(usage), do: total
  end

  @spec held?(Status.t() | nil) :: boolean()
  defp held?(%Status{state: :held}), do: true
  defp held?(%Status{held?: true}), do: true
  defp held?(_status), do: false

  @spec latest_stage(map()) :: atom() | nil
  defp latest_stage(entered) do
    [:reviewing | @implementing_states]
    |> Enum.map(fn stage -> {stage, entered_at(entered, stage)} end)
    |> Enum.reject(fn {_stage, at} -> is_nil(at) end)
    |> Enum.max_by(fn {_stage, at} -> DateTime.to_unix(at, :microsecond) end, fn -> {nil, nil} end)
    |> elem(0)
  end

  @spec entered_at(map(), atom()) :: DateTime.t() | nil
  defp entered_at(entered, stage) do
    Map.get(entered, stage) || Map.get(entered, Atom.to_string(stage))
  end

  @spec index_live([Status.t()]) :: %{optional({String.t(), String.t()}) => Status.t()}
  defp index_live(runs) do
    runs
    |> Enum.flat_map(fn status ->
      Enum.map(Enum.uniq([status.task_id | status.task_ids]), &{{status.project_name, to_string(&1)}, status})
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {identity, attempts} ->
      selected = Enum.max_by(attempts, &{&1.state not in @terminal_states, record_recency(&1)})
      {identity, selected}
    end)
  end

  @spec index_records([LogRecord.t()]) :: %{optional({String.t(), String.t()}) => [LogRecord.t()]}
  defp index_records(records) do
    Enum.reduce(records, %{}, fn %LogRecord{} = record, acc ->
      Enum.reduce(record_task_ids(record), acc, fn task_id, inner ->
        Map.update(inner, {record.project_name, task_id}, [record], &(&1 ++ [record]))
      end)
    end)
  end

  @spec record_task_ids(LogRecord.t()) :: [String.t()]
  defp record_task_ids(%LogRecord{task_id: task_id, task_ids: ids}) when is_list(ids) and ids != [] do
    Enum.uniq(Enum.map([task_id | ids], &to_string/1))
  end

  defp record_task_ids(%LogRecord{task_id: task_id}), do: [to_string(task_id)]

  @spec bound_done(%{optional(lane()) => [Card.t()]}, pos_integer()) :: %{optional(lane()) => [Card.t()]}
  defp bound_done(grouped, limit) do
    Map.update(grouped, :done, [], fn cards ->
      cards
      |> Enum.group_by(& &1.project_name)
      |> Enum.flat_map(fn {_project, project_cards} ->
        project_cards |> Enum.sort_by(&done_sort_key/1, :desc) |> Enum.take(limit)
      end)
      |> Enum.sort_by(&{&1.project_name, done_sort_key(&1)}, :desc)
    end)
  end

  @spec done_sort_key(Card.t()) :: tuple()
  defp done_sort_key(%Card{done_at: done_at, task_id: task_id}) do
    {done_at || "", numeric_task_key(task_id), task_id}
  end

  @spec fill_lanes(%{optional(lane()) => [Card.t()]}) :: %{lane() => [Card.t()]}
  defp fill_lanes(grouped) do
    Map.merge(Map.new(@lanes, &{&1, []}), grouped)
  end

  @spec task_id(map()) :: String.t()
  defp task_id(%{"id" => id}), do: to_string(id)
  defp task_id(_task), do: ""

  @spec numeric_task_key(String.t()) :: integer()
  defp numeric_task_key(task_id) do
    case Integer.parse(task_id) do
      {int, ""} -> int
      _other -> 0
    end
  end

  @spec present(term()) :: String.t() | nil
  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil
end
