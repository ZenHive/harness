defmodule Harness.Cron.UnroutableNotice do
  @moduledoc """
  In-memory memory of which ready-but-unroutable tasks the operator has already
  been told about.

  A ready task whose `assignee` is `human`, missing, or unknown carries no
  autonomous dispatch intent, so `Harness.Cron.RoadmapPoller` drops it from the
  wave. Dropping it *silently* is the failure this store exists to prevent: the
  task is queue-ready, nothing will ever pick it up, and the only trace was a
  `Logger.debug` line nobody reads. The poller now fires a witness event for it —
  but the poller ticks on a schedule, and re-announcing the same parked task
  every tick trains the operator to ignore the channel.

  So the notice is **transition-only**, the same contract
  `Harness.Cron.PendingDispatch.park/4` gives a parked decision: announce the
  first time a `{task_id, assignee}` pair shows up unroutable, stay quiet while
  it stays that way.

  ## Set replacement, not accumulation

  `fresh/2` takes the project's *whole* unroutable set for this tick and replaces
  what it remembered, returning only the entries that were not already there.
  Replacement is what makes the store self-clearing: a task that gets an agent
  assignee, is completed, or leaves the ready set simply stops appearing in the
  tick's set and is forgotten — so if it ever goes unroutable again it announces
  again. Keying on `{task_id, assignee}` rather than the id alone means a
  re-routing from `human` to no assignee at all is a new fact and re-announces.

  ## Not persisted, by design

  Entries live in `GenServer` state only. A BEAM restart clears them, so the
  first tick after a restart re-announces everything still unroutable — the safe
  direction for a witness: a restart costs the operator a repeat, never a miss.
  """

  use GenServer

  @typedoc "One unroutable task: its id and the raw assignee that failed to route."
  @type entry :: {String.t(), String.t() | nil}

  @typep state :: %{String.t() => MapSet.t(entry())}

  @doc false
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(init_arg \\ []) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl GenServer
  @spec init(term()) :: {:ok, state()}
  def init(_init_arg), do: {:ok, %{}}

  @doc """
  Records `entries` as `project_name`'s current unroutable set, returning the
  entries that were not already recorded — the ones worth announcing.

  Order is preserved from `entries`, so the caller announces in roadmap order. An
  empty list forgets the project entirely.
  """
  @spec fresh(String.t(), [entry()]) :: [entry()]
  def fresh(project_name, entries) when is_binary(project_name) and is_list(entries) do
    GenServer.call(__MODULE__, {:fresh, project_name, entries})
  end

  @doc "Forgets every remembered notice (test seam)."
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl GenServer
  def handle_call({:fresh, project_name, []}, _from, state) do
    {:reply, [], Map.delete(state, project_name)}
  end

  def handle_call({:fresh, project_name, entries}, _from, state) do
    known = Map.get(state, project_name, MapSet.new())
    new_entries = Enum.reject(entries, &MapSet.member?(known, &1))

    {:reply, new_entries, Map.put(state, project_name, MapSet.new(entries))}
  end

  def handle_call(:reset, _from, _state), do: {:reply, :ok, %{}}
end
