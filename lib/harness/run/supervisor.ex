defmodule Harness.Run.Supervisor do
  @moduledoc """
  Supervises admission, concurrent run lifecycles, and the shutdown fence.

  One harness instance runs many concurrent jobs; each is a `Harness.Run`
  `:gen_statem` started under the inner DynamicSupervisor as a `:temporary`
  child. The `:one_for_one`
  strategy is the crash-isolation guarantee — a run that crashes is removed
  without restart and without touching a sibling. A failed run is a *reported
  outcome*, not a fault to retry, so children are never restarted.

  `start_run/4` is the entry point: it generates the run id, threads it (and the
  caller as the default result subscriber) into the run, and returns the id so
  the caller can later query `Harness.Run.status/1` or `Harness.Run.cancel/1`.
  """

  use Supervisor
  use Descripex, namespace: "/run/supervisor"

  alias Harness.AgentRegistry
  alias Harness.Project
  alias Harness.Roadmap.Item
  alias Harness.Run
  alias Harness.Run.Admission

  @registry Harness.Run.Registry

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(init_arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [init_arg]}, type: :supervisor}
  end

  api(:start_link, "Start the Harness.Run supervision tree (one per node, registered as Harness.Run.Supervisor).",
    params: [
      init_arg: [
        kind: :value,
        default: [],
        description: "Options for the run supervision tree — typically [] from the Application."
      ]
    ],
    returns: %{type: :tuple, description: "{:ok, pid()} or Supervisor.on_start error."}
  )

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: Keyword.get(init_arg, :name, __MODULE__))
  end

  @doc false
  @impl Supervisor
  @spec init(keyword()) :: {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec()]}}
  def init(opts) do
    admission = Keyword.get(opts, :admission, Admission)
    runs = Keyword.get(opts, :runs, Harness.Run.DynamicSupervisor)

    # Reverse OTP teardown closes admission, then stops runs concurrently, then
    # stops the gate. The task supervisor and stores are owned by the parent.
    Supervisor.init(
      [
        Supervisor.child_spec({Admission, name: admission, runs: runs}, shutdown: 1_000),
        {DynamicSupervisor, name: runs, strategy: :one_for_one},
        Supervisor.child_spec({Harness.Run.Shutdown, admission: admission}, shutdown: 7_000)
      ],
      strategy: :one_for_all
    )
  end

  api(
    :start_run,
    "Start a supervised Harness.Run lifecycle for one rmap task against a project, driven by an agent adapter.",
    params: [
      item: [
        kind: :exchange_data,
        source: "Harness.Roadmap.ingest/2",
        description: "%Harness.Roadmap.Item{} — ingest first via Harness.Roadmap.ingest/2."
      ],
      project: [
        kind: :exchange_data,
        source: "Harness.ProjectRegistry.lookup/1",
        description: "%Harness.Project{} — look up first via Harness.ProjectRegistry.lookup/1."
      ],
      adapter: [
        kind: :value,
        description:
          "Adapter module (Harness.AgentAdapter.Claude / .Codex / .Cursor / .Grok / .Antigravity / .Pi). Caller picks the agent."
      ],
      opts: [
        kind: :value,
        default: [],
        description:
          ~s|Keyword list. :subscriber (pid receiving {:harness_run, run_id, result}; pass nil from ephemeral MCP eval). :run_id (override the generated id). :total_timeout / :idle_timeout / :progress_timeout (agent run budgets in ms). :lifetime_timeout (whole-job wall budget). :terminal_linger (how long a settled run stays observable). :checks / :verification_timeout (override verification stack). :base_dir / :base_ref (worktree root + commit-ish). :adapter_opts (per-agent knobs). :env (%{"KEY" => "val"} to set, %{"KEY" => false} to scrub — used to strip ANTHROPIC_API_KEY on Claude OAuth dispatches). :required_capabilities. :pollution_allowlist.|
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, run_id, pid} — run_id is the stable handle for Harness.Run.status/1 and Harness.Run.cancel/1. {:error, reason} on dispatch failure."
    }
  )

  @spec start_run(Item.t(), Project.t(), module(), keyword()) ::
          {:ok, String.t(), pid()} | {:error, term()}
  def start_run(%Item{} = item, %Project{} = project, adapter, opts \\ []) when is_atom(adapter) and is_list(opts) do
    with {:ok, ^adapter} <-
           AgentRegistry.select(adapter, required_capabilities: Keyword.get(opts, :required_capabilities, [])) do
      run_id = Keyword.get(opts, :run_id) || generate_run_id()
      admission = Keyword.get(opts, :admission, Admission)
      opts = opts |> Keyword.put(:run_id, run_id) |> Keyword.put_new(:subscriber, self())
      opts = Keyword.put(opts, :shutdown_token, Admission.token(admission))

      case Admission.start_run(admission, {Run, {item, project, adapter, opts}}) do
        {:ok, pid} -> {:ok, run_id, pid}
        {:error, _reason} = error -> error
      end
    end
  end

  api(:list_runs, "List the ids of every Harness.Run currently registered — in flight or lingering in a terminal state.",
    returns: %{
      type: :list,
      description:
        "List of run id strings. Source-of-truth for Harness.Run.status/1, Harness.Run.transcript/1, Harness.Run.cancel/1 inputs."
    }
  )

  @spec list_runs() :: [String.t()]
  def list_runs do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  # A unique run id, shared by the gen_statem registration, the worktree
  # directory, and the `harness/<id>` branch — so a retained worktree traces
  # straight back to its run.
  @spec generate_run_id() :: String.t()
  defp generate_run_id do
    rand = 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    "run-#{System.system_time(:millisecond)}-#{rand}"
  end
end
