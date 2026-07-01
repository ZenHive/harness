defmodule Harness.Cron.PendingDispatch do
  @moduledoc """
  In-memory store for autonomous-dispatch decisions parked for operator approval
  (Task 237).

  When a project's cron dispatch mode is `:manual` (`Harness.Cron.Settings`), the
  poller does NOT enqueue an autonomously-selected run. Instead the *resolved*
  decision — task id + adapter module + the same env scrub the auto path would
  apply — is parked here, and an operator drains it later with `approve/1`. The
  orchestrator AI still makes every judgment (which tasks, which adapter); this
  store only HOLDS the mechanical enqueue until an operator approves.

  ## Mechanical only

  The store counts and holds facts: a `{project_name, task_id}` keys one parked
  record. `park/4` is idempotent over that key, so re-parking across cron ticks
  (the task stays pending until approved) never accumulates duplicates — mirroring
  the Oban unique-insert dedup on the `:auto` path. `approve/1` atomically claims
  a record before enqueuing, so two concurrent approvals can never double-enqueue.

  ## Not persisted, by design

  Parked records live in `GenServer` state only — a BEAM restart clears them, the
  same soft-state contract as `Harness.AgentRegistry` availability. Correctness
  lives below: an un-approved task stays pending, so the next cron tick simply
  re-parks it. Persisting a parked decision across a restart would re-offer a
  decision the operator may no longer want against a roadmap that has moved on.
  """

  use GenServer

  alias Harness.AgentRegistry
  alias Harness.ProjectRegistry
  alias Harness.Roadmap
  alias Harness.Run.Worker, as: RunWorker

  @typedoc "A parked autonomous-dispatch decision awaiting operator approval."
  @type t :: %__MODULE__{
          id: String.t(),
          project_name: String.t(),
          task_id: String.t(),
          adapter: module(),
          env: %{optional(String.t()) => false},
          parked_at: DateTime.t()
        }

  @typep status :: :parked | :claimed
  @typep state :: %{String.t() => {status(), t()}}

  @enforce_keys [:id, :project_name, :task_id, :adapter, :env, :parked_at]
  defstruct [:id, :project_name, :task_id, :adapter, :env, :parked_at]

  @doc false
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(init_arg \\ []) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl GenServer
  @spec init(term()) :: {:ok, state()}
  def init(_init_arg), do: {:ok, %{}}

  @doc """
  Parks a resolved dispatch decision for operator approval.

  Idempotent over `{project_name, task_id}`: re-parking the same task returns
  `{:exists, record}` without creating a duplicate (so cron re-ticks are inert),
  while a fresh decision returns `{:parked, record}`.
  """
  @spec park(String.t(), String.t(), module(), %{optional(String.t()) => false}) ::
          {:parked, t()} | {:exists, t()}
  def park(project_name, task_id, adapter, env)
      when is_binary(project_name) and is_binary(task_id) and is_atom(adapter) and is_map(env) do
    GenServer.call(__MODULE__, {:park, project_name, task_id, adapter, env})
  end

  @doc "Lists all parked decisions, oldest first."
  @spec list() :: [t()]
  def list, do: GenServer.call(__MODULE__, :list)

  @doc """
  Approves a parked decision by `id`, draining it into `Harness.Run.Worker.enqueue/4`.

  Atomically claims the record first, so a second approval of the same id (or an
  unknown id) is a harmless `{:error, :not_found}` — the idempotency guard that
  makes double-enqueue impossible. On an enqueue failure the record is re-parked
  so the operator can retry.
  """
  @spec approve(String.t()) ::
          {:ok, %{run_id: String.t(), task_id: String.t(), project_name: String.t(), adapter: module()}}
          | {:error, :not_found | term()}
  def approve(id) when is_binary(id) do
    case GenServer.call(__MODULE__, {:claim, id}) do
      {:ok, %__MODULE__{} = record} -> enqueue(record)
      :error -> {:error, :not_found}
    end
  end

  @doc false
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl GenServer
  def handle_call({:park, project_name, task_id, adapter, env}, _from, state) do
    id = id_for(project_name, task_id)

    case Map.fetch(state, id) do
      {:ok, {_status, record}} ->
        {:reply, {:exists, record}, state}

      :error ->
        record = %__MODULE__{
          id: id,
          project_name: project_name,
          task_id: task_id,
          adapter: adapter,
          env: env,
          parked_at: DateTime.utc_now()
        }

        {:reply, {:parked, record}, Map.put(state, id, {:parked, record})}
    end
  end

  def handle_call(:list, _from, state) do
    records =
      state
      |> Map.values()
      |> Enum.flat_map(fn
        {:parked, record} -> [record]
        {:claimed, _record} -> []
      end)
      |> Enum.sort_by(& &1.parked_at, DateTime)

    {:reply, records, state}
  end

  def handle_call({:claim, id}, _from, state) do
    case Map.fetch(state, id) do
      {:ok, {:parked, %__MODULE__{} = record}} ->
        {:reply, {:ok, record}, Map.put(state, id, {:claimed, record})}

      {:ok, {:claimed, %__MODULE__{}}} ->
        {:reply, :error, state}

      :error ->
        {:reply, :error, state}
    end
  end

  def handle_call({:repark, %__MODULE__{id: id} = record}, _from, state) do
    {:reply, :ok, Map.put(state, id, {:parked, record})}
  end

  def handle_call({:complete, id}, _from, state) do
    {:reply, :ok, Map.delete(state, id)}
  end

  def handle_call(:reset, _from, _state), do: {:reply, :ok, %{}}

  # Drains a claimed record into the normal dispatch path. Re-ingests the task by
  # id so the worker receives a real `%Item{}`; the worker re-ingests internally,
  # so only `item.id` is load-bearing here — the env scrub captured at park time
  # is threaded so an approved run honours the same secret-scrub the auto path
  # would have applied.
  @spec enqueue(t()) ::
          {:ok, %{run_id: String.t(), task_id: String.t(), project_name: String.t(), adapter: module()}}
          | {:error, term()}
  defp enqueue(%__MODULE__{} = record) do
    with {:ok, project} <- lookup_project(record.project_name),
         {:ok, agent} <- AgentRegistry.agent_for_module(record.adapter),
         {:ok, item} <- ingest_roadmap({:id, record.task_id}, project: project, agent: agent),
         {:ok, run_id, _job} <- RunWorker.enqueue(project, item, record.adapter, env: record.env) do
      GenServer.call(__MODULE__, {:complete, record.id})
      {:ok, %{run_id: run_id, task_id: record.task_id, project_name: record.project_name, adapter: record.adapter}}
    else
      {:error, _reason} = error ->
        GenServer.call(__MODULE__, {:repark, record})
        error
    end
  end

  @spec lookup_project(String.t()) :: {:ok, Harness.Project.t()} | {:error, {:unknown_project, String.t()}}
  defp lookup_project(name) do
    case ProjectRegistry.lookup(name) do
      {:ok, project} -> {:ok, project}
      {:error, _reason} -> {:error, {:unknown_project, name}}
    end
  end

  # Test seam shared with `Harness.Run.Worker`: a `:roadmap_ingest` arity-2 fn
  # lets approval tests inject a fake item without rmap. Never set in production.
  @spec ingest_roadmap(Roadmap.selector(), keyword()) :: {:ok, Roadmap.Item.t()} | {:error, term()}
  defp ingest_roadmap(selector, opts) do
    case Application.get_env(:harness, :roadmap_ingest) do
      fun when is_function(fun, 2) -> fun.(selector, opts)
      _other -> Roadmap.ingest(selector, opts)
    end
  end

  @spec id_for(String.t(), String.t()) :: String.t()
  defp id_for(project_name, task_id), do: "#{project_name}:#{task_id}"
end
