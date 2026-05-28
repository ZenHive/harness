defmodule Harness.Run.Supervisor do
  @moduledoc """
  The `DynamicSupervisor` under which every `Harness.Run` lifecycle starts.

  One harness instance runs many concurrent jobs; each is a `Harness.Run`
  `:gen_statem` started here as a `:temporary` child. The `:one_for_one`
  strategy is the crash-isolation guarantee — a run that crashes is removed
  without restart and without touching a sibling. A failed run is a *reported
  outcome*, not a fault to retry, so children are never restarted.

  `start_run/4` is the entry point: it generates the run id, threads it (and the
  caller as the default result subscriber) into the run, and returns the id so
  the caller can later query `Harness.Run.status/1` or `Harness.Run.cancel/1`.
  """

  use DynamicSupervisor
  use Descripex, namespace: "/run/supervisor"

  alias Harness.AgentRegistry
  alias Harness.Project
  alias Harness.Roadmap.Item
  alias Harness.Run

  @registry Harness.Run.Registry

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(init_arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [init_arg]}, type: :supervisor}
  end

  api(:start_link, "Start the Harness.Run DynamicSupervisor (one per node, registered as Harness.Run.Supervisor).",
    params: [
      init_arg: [
        kind: :value,
        default: [],
        description: "DynamicSupervisor init term — typically [] from the Application supervision tree."
      ]
    ],
    returns: %{type: :tuple, description: "{:ok, pid()} or DynamicSupervisor.on_start error."}
  )

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg \\ []) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc false
  @impl DynamicSupervisor
  @spec init(term()) :: {:ok, DynamicSupervisor.sup_flags()}
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
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
          ~s|Keyword list. :subscriber (pid receiving {:harness_run, run_id, result}; pass nil from ephemeral MCP eval). :run_id (override the generated id). :total_timeout / :idle_timeout (agent run budgets in ms). :lifetime_timeout (whole-job wall budget). :terminal_linger (how long a settled run stays observable). :checks / :verification_timeout (override verification stack). :base_dir / :base_ref (worktree root + commit-ish). :adapter_opts (per-agent knobs). :env (%{"KEY" => "val"} to set, %{"KEY" => false} to scrub — used to strip ANTHROPIC_API_KEY on Claude OAuth dispatches). :required_capabilities. :retry_policy. :pollution_allowlist.|
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
      opts = opts |> Keyword.put(:run_id, run_id) |> Keyword.put_new(:subscriber, self())

      case DynamicSupervisor.start_child(__MODULE__, {Run, {item, project, adapter, opts}}) do
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
