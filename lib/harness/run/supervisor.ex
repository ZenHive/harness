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

  alias Harness.Roadmap.Item
  alias Harness.Run

  @registry Harness.Run.Registry

  @doc """
  Starts the run supervisor. Named `Harness.Run.Supervisor`; one per node.
  """
  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg \\ []) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl DynamicSupervisor
  @spec init(term()) :: {:ok, DynamicSupervisor.sup_flags()}
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a supervised `Harness.Run` for `item` against `repo`, driven by `adapter`.

  `item` is the ingested rmap task, `repo` the target repository the run carves
  its isolated worktree from, and `adapter` the `Harness.AgentAdapter` module
  that dispatches the headless agent.

  Returns `{:ok, run_id, pid}` — the `run_id` is the stable handle for
  `Harness.Run.status/1` and `Harness.Run.cancel/1`.

  Options (all optional unless noted):

    * `:subscriber` — pid that receives `{:harness_run, run_id, result}` when the
      run settles. Defaults to the calling process.
    * `:run_id` — override the generated run id (intended for tests).
    * `:total_timeout` / `:idle_timeout` — agent run timeouts, passed through to
      `Harness.AgentAdapter.Driver`.
    * `:lifetime_timeout` — whole-job wall budget in ms.
    * `:terminal_linger` — how long a settled run stays observable, in ms.
    * `:checks` / `:verification_timeout` — override the verification stack and
      its per-check timeout.
    * `:base_dir` / `:base_ref` — worktree root and the commit-ish to branch
      from, passed through to `Harness.Worktree.create/2`.
    * `:adapter_opts` — per-agent knobs, passed through to the invocation.
    * `:env` — map of env vars for the dispatched agent (`%{"KEY" => "val"}` to
      set, `%{"KEY" => false}` to scrub/unset); threaded to `Invocation` and
      every adapter's `build_command/1`.
    * `:retry_policy` — `%Harness.Run.RetryPolicy{}` or keyword list for
      `Harness.Run.RetryPolicy.from_opts/1` when a caller wraps runs with
      `RetryPolicy.run/2` (batch or per-run scope).
  """
  @spec start_run(Item.t(), String.t(), module(), keyword()) ::
          {:ok, String.t(), pid()} | {:error, term()}
  def start_run(%Item{} = item, repo, adapter, opts \\ []) when is_binary(repo) and is_atom(adapter) and is_list(opts) do
    run_id = Keyword.get(opts, :run_id) || generate_run_id()
    opts = opts |> Keyword.put(:run_id, run_id) |> Keyword.put_new(:subscriber, self())

    case DynamicSupervisor.start_child(__MODULE__, {Run, {item, repo, adapter, opts}}) do
      {:ok, pid} -> {:ok, run_id, pid}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Lists the ids of every run currently registered — in flight or lingering in a
  terminal state.
  """
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
