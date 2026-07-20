defmodule Harness.Oban do
  @moduledoc """
  Supervised Oban instance for persisted harness dispatch.

  Harness uses one Oban queue per registered project. Open-source Oban enforces
  each queue's local limit independently, so total local concurrency is the sum
  of all project queue limits.
  """

  use Supervisor

  import Ecto.Query, only: [from: 2]

  alias Harness.Cron.DepFreshnessPoller
  alias Harness.Cron.RoadmapPoller
  alias Harness.Cron.SuiteHealthPoller
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Oban.Plugins.Lifeline

  @default_queue_limit 1
  @lifeline_rescue_after_ms to_timeout(minute: 30)
  @headroom_states ~w(available scheduled executing retryable)
  @run_worker Oban.Worker.to_string(Harness.Run.Worker)
  @orphan_rescue_child_id Harness.Oban.OrphanedRunRescue

  # The "is a job tracked?" reads degrade to an empty answer when the repo/Oban is
  # not running (RuntimeError from the repo lookup) or a DB query fails. The `in`
  # filter lets a genuine code bug crash instead of being hidden as false/[].
  @query_degrade_errors [
    RuntimeError,
    DBConnection.ConnectionError,
    DBConnection.OwnershipError,
    Postgrex.Error,
    Ecto.QueryError,
    ArgumentError
  ]

  @doc false
  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: Harness.Oban.Supervisor)
  end

  @impl Supervisor
  @spec init(term()) :: {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec()]}}
  def init(_init_arg) do
    children = [
      {Oban, oban_opts()},
      orphan_rescue_child(),
      Harness.Oban.QueueBootstrap
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Inserts an Oban job through the harness instance.
  """
  @spec insert(Ecto.Changeset.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def insert(changeset) do
    case Application.get_env(:harness, :oban_insert) do
      fun when is_function(fun, 1) -> fun.(changeset)
      _other -> Oban.insert(__MODULE__, changeset)
    end
  end

  @doc """
  Returns whether a non-terminal run worker job already exists for `project` and `item_id`.

  Used by manual cron dispatch approval to preserve the auto path's duplicate
  protection after an approved job has been enqueued.
  """
  @spec unfinished_run_job?(Project.t(), String.t()) :: boolean()
  def unfinished_run_job?(%Project{} = project, item_id) when is_binary(item_id) do
    queue = queue_name(project)

    query =
      from(job in Oban.Job,
        where:
          job.queue == ^queue and job.worker == ^@run_worker and job.state in ^@headroom_states and
            fragment("?->>? = ?", job.args, "project_name", ^project.name) and
            fragment("?->>? = ?", job.args, "item_id", ^item_id),
        limit: 1
      )

    Harness.Repo.exists?(query)
  rescue
    _error in @query_degrade_errors -> false
  end

  @doc false
  @spec coalesced_run_job(Project.t(), String.t()) :: {:ok, Oban.Job.t()} | :error
  def coalesced_run_job(%Project{} = project, item_id) when is_binary(item_id) do
    query =
      from(job in Oban.Job,
        where:
          job.queue == ^queue_name(project) and job.worker == ^@run_worker and job.state in ^@headroom_states and
            fragment("?->>? = ?", job.args, "project_name", ^project.name) and
            fragment("?->'item_ids' @> ?::jsonb", job.args, ^Jason.encode!([item_id])),
        limit: 1
      )

    case Harness.Repo.one(query) do
      %Oban.Job{} = job -> {:ok, job}
      nil -> :error
    end
  rescue
    _error in @query_degrade_errors -> :error
  end

  @doc """
  Starts or scales the queues for `project` when Oban is running normally.

  Each project gets two queues: the dispatch queue (`project_<name>`, sized to
  the concurrency cap) and the landing queue (`landing_<name>`, fixed at limit 1
  so the autonomous merge-train lands one approved run at a time per project).
  """
  @spec ensure_project_queue(Project.t()) :: :ok | {:error, term()}
  def ensure_project_queue(%Project{} = project) do
    if queues_enabled?() and oban_running?() do
      with :ok <-
             Oban.start_queue(__MODULE__,
               queue: queue_name(project),
               limit: queue_limit(project),
               local_only: true
             ) do
        Oban.start_queue(__MODULE__,
          queue: landing_queue_name(project),
          limit: 1,
          local_only: true
        )
      end
    else
      :ok
    end
  end

  @doc """
  Returns the Oban dispatch-queue name for a project.
  """
  @spec queue_name(Project.t() | String.t()) :: String.t()
  def queue_name(%Project{name: name}), do: queue_name(name)
  def queue_name(name) when is_binary(name), do: "project_#{name}"

  @doc """
  Threads a caller `:env` map from `opts` into Oban job `args`.

  An optional caller env map (e.g. `%{"ANTHROPIC_API_KEY" => false}` to scrub a
  metered key on Claude OAuth dispatches) is persisted into the job args so the
  run worker can thread it into `start_run`. Omitted when empty so jobs without
  an env override keep their prior args shape; the map must be jsonb-safe
  (string keys, `string | false` values).
  """
  @spec put_env_arg(map(), keyword()) :: map()
  def put_env_arg(args, opts) when is_map(args) and is_list(opts) do
    case Keyword.get(opts, :env, %{}) do
      env when is_map(env) and map_size(env) > 0 -> Map.put(args, :env, env)
      _empty -> args
    end
  end

  @doc """
  Returns the Oban landing-queue name for a project (`landing_<name>`).
  """
  @spec landing_queue_name(Project.t() | String.t()) :: String.t()
  def landing_queue_name(%Project{name: name}), do: landing_queue_name(name)
  def landing_queue_name(name) when is_binary(name), do: "landing_#{name}"

  @doc """
  Returns the branches the merge-train is currently tracking for `project`.

  A branch is *tracked* while a landing job for it is unfinished (available /
  scheduled / executing / retryable) on the serialized `landing_<name>` queue.
  This is the **observable guard** behind the read-only-witness contract: the only
  way a branch lands is through this queue, so a witness — human or a buddhi sink
  deciding whether to act — can ask "is the train already on this?" before
  touching it, rather than racing the train by hand-merging. Returns `[]` when
  nothing is tracked (or the repo/Oban is not running).
  """
  @spec tracked_landing_branches(Project.t() | String.t()) :: [String.t()]
  def tracked_landing_branches(project) do
    queue = landing_queue_name(project)

    query =
      from(job in Oban.Job,
        where: job.queue == ^queue and job.state in ^@headroom_states,
        select: job.args
      )

    query
    |> Harness.Repo.all()
    |> Enum.map(&Map.get(&1, "branch"))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  rescue
    _error in @query_degrade_errors -> []
  end

  @doc false
  @spec bootstrap_project_queues() :: :ok
  def bootstrap_project_queues do
    Enum.each(ProjectRegistry.list(), &ensure_project_queue/1)
  end

  @doc false
  @spec rescue_orphaned_run_jobs() :: :ok
  def rescue_orphaned_run_jobs do
    Harness.Run.Supervisor.list_runs()
    |> MapSet.new()
    |> rescue_orphaned_executing_jobs()
  end

  @doc false
  @spec oban_opts() :: keyword()
  def oban_opts do
    base =
      :harness
      |> Application.get_env(Oban, [])
      |> Keyword.put_new(:name, __MODULE__)
      |> Keyword.put_new(:repo, Harness.Repo)
      |> Keyword.put_new(:queues, [])

    base
    |> enable_cron_queue()
    |> enable_suite_health_queue()
    |> enable_audit_queue()
    |> enable_lifeline_plugin()
    |> enable_cron_plugin()
    |> Keyword.put(:name, __MODULE__)
  end

  @doc false
  @spec queue_headroom?(Project.t()) :: boolean()
  def queue_headroom?(%Project{} = project) do
    if queues_enabled?() and oban_running?() do
      queued_job_count(project) < queue_limit(project)
    else
      true
    end
  end

  # Oban registers its instance through `Oban.Registry` ({:via, ...}), never as a
  # globally-named process — so `Process.whereis(Harness.Oban)` is always nil even
  # when Oban is fully running, and the old guard silently skipped every queue
  # start (queues never left [:cron] at boot; Task 133). `Oban.whereis/1` is the
  # registry-aware liveness check and returns the supervisor pid (or nil).
  @spec oban_running?() :: boolean()
  defp oban_running? do
    is_pid(Oban.whereis(__MODULE__))
  end

  # Public (internal) so the sibling `ProjectRegistry` queue-bootstrap path shares
  # this single definition instead of duplicating the testing-config check.
  @doc false
  @spec queues_enabled?() :: boolean()
  def queues_enabled? do
    :harness
    |> Application.get_env(Oban, [])
    |> Keyword.get(:testing, :disabled)
    |> Kernel.==(:disabled)
  end

  # Public (internal) so the sibling `ProjectRegistry` queue-bootstrap path shares
  # this single definition instead of duplicating the cap → limit derivation.
  @doc false
  @spec queue_limit(Project.t()) :: pos_integer()
  def queue_limit(%Project{concurrency_cap: cap}) when is_integer(cap) and cap > 0, do: cap
  def queue_limit(%Project{}), do: @default_queue_limit

  @spec queued_job_count(Project.t()) :: non_neg_integer()
  defp queued_job_count(%Project{} = project) do
    queue = queue_name(project)

    query =
      from(job in Oban.Job,
        where: job.queue == ^queue and job.state in ^@headroom_states
      )

    Harness.Repo.aggregate(query, :count, :id)
  end

  @spec orphan_rescue_child() :: Supervisor.child_spec()
  defp orphan_rescue_child do
    # reach:disable-next-line fixed_shape_map — standard OTP Supervisor.child_spec/1 literal
    %{
      id: @orphan_rescue_child_id,
      start: {Task, :start_link, [&rescue_orphaned_run_jobs/0]},
      restart: :temporary
    }
  end

  # Per-job liveness: rescue every `executing` Run.Worker job whose run is NOT
  # live in this BEAM, rather than refusing the whole rescue when any one run is
  # registered. The old all-or-nothing left genuinely-orphaned jobs from a prior
  # crashed boot stuck `executing` forever whenever a single unrelated run was
  # live. A job is left alone only when its `run_id` arg matches a registered run
  # (the live run owns its worktree+branch and settles on its own); a job whose
  # run_id is absent (legacy) or unregistered is orphaned and made runnable.
  @spec rescue_orphaned_executing_jobs(MapSet.t(String.t())) :: :ok
  defp rescue_orphaned_executing_jobs(live_run_ids) do
    query =
      from(job in Oban.Job,
        where: job.worker == ^@run_worker and job.state == "executing",
        select: {job.id, job.args}
      )

    orphan_ids =
      query
      |> Harness.Repo.all()
      |> Enum.reject(fn {_id, args} -> MapSet.member?(live_run_ids, Map.get(args, "run_id")) end)
      |> Enum.map(fn {id, _args} -> id end)

    mark_jobs_available(orphan_ids)
  end

  @spec mark_jobs_available([integer()]) :: :ok
  defp mark_jobs_available([]), do: :ok

  defp mark_jobs_available(job_ids) do
    query = from(job in Oban.Job, where: job.id in ^job_ids)
    {_count, _jobs} = Harness.Repo.update_all(query, set: [state: "available"])
    :ok
  end

  # The cron queue + Cron plugin register UNCONDITIONALLY (not gated on
  # RoadmapPoller.enabled?/0). Whether a tick *dispatches* is decided live inside
  # RoadmapPoller.perform/1 via enabled?/0; whether a tick is *scheduled* must not
  # depend on the boot-time flag, or the runtime master toggle (Task 109) would
  # have nothing to act on when autonomy was OFF at boot. Oban's `testing` modes
  # suppress Cron scheduling, so always-registering is inert in tests.
  @spec enable_cron_queue(keyword()) :: keyword()
  defp enable_cron_queue(opts) do
    {queue, limit} = RoadmapPoller.cron_queue_config()

    Keyword.update(opts, :queues, [{queue, limit}], fn
      queues when is_list(queues) -> Keyword.put_new(queues, queue, limit)
      _other -> [{queue, limit}]
    end)
  end

  # The suite-health queue: its own limit-1 queue so a long full-suite run
  # (all projects, integration included) never occupies the shared :cron slot
  # the roadmap and dep-freshness pollers tick on.
  @spec enable_suite_health_queue(keyword()) :: keyword()
  defp enable_suite_health_queue(opts) do
    {queue, limit} = SuiteHealthPoller.queue_config()

    Keyword.update(opts, :queues, [{queue, limit}], fn
      queues when is_list(queues) -> Keyword.put_new(queues, queue, limit)
      _other -> [{queue, limit}]
    end)
  end

  # The post-merge audit queue: one global queue at limit 1 — audit agent runs
  # are best-effort and serialized so concurrent lands across projects don't
  # stack agent processes. Job dedup per project lives on the worker's unique
  # options (Harness.Audit.Worker.unique_opts/0).
  @spec enable_audit_queue(keyword()) :: keyword()
  defp enable_audit_queue(opts) do
    Keyword.update(opts, :queues, [audit: 1], fn
      queues when is_list(queues) -> Keyword.put_new(queues, :audit, 1)
      _other -> [audit: 1]
    end)
  end

  @spec enable_lifeline_plugin(keyword()) :: keyword()
  defp enable_lifeline_plugin(opts) do
    plugin = {Lifeline, rescue_after: @lifeline_rescue_after_ms}

    Keyword.update(opts, :plugins, [plugin], fn
      plugins when is_list(plugins) -> Keyword.put_new(plugins, Lifeline, rescue_after: @lifeline_rescue_after_ms)
      _other -> [plugin]
    end)
  end

  @spec enable_cron_plugin(keyword()) :: keyword()
  defp enable_cron_plugin(opts) do
    plugin = {Oban.Plugins.Cron, crontab: cron_crontab()}

    Keyword.update(opts, :plugins, [plugin], fn
      plugins when is_list(plugins) -> plugins ++ [plugin]
      _other -> [plugin]
    end)
  end

  @spec cron_crontab() :: [{String.t(), module(), keyword()}]
  defp cron_crontab do
    [
      RoadmapPoller.cron_entry(),
      DepFreshnessPoller.cron_entry(),
      SuiteHealthPoller.cron_entry()
    ]
  end
end
