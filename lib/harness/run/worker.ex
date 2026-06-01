defmodule Harness.Run.Worker do
  @moduledoc """
  Oban worker that turns a persisted job row into a supervised harness run.
  """

  use Oban.Worker, queue: :default, max_attempts: 20

  alias Harness.AgentRegistry
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.Roadmap
  alias Harness.Roadmap.Item
  alias Harness.Run.FailureClass
  alias Harness.Run.Result
  alias Harness.Run.RetryPolicy
  alias Harness.Run.Supervisor, as: RunSupervisor

  require Logger

  @type args :: %{
          required(String.t()) => String.t()
        }

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(%Oban.Job{args: args} = job) do
    with {:ok, project_name} <- fetch_arg(args, "project_name"),
         {:ok, item_id} <- fetch_arg(args, "item_id"),
         {:ok, adapter_name} <- fetch_arg(args, "adapter_module"),
         {:ok, project} <- ProjectRegistry.lookup(project_name),
         {:ok, adapter} <- adapter_module(adapter_name),
         {:ok, agent} <- agent_for_adapter(adapter),
         {:ok, %Item{} = item} <- ingest_roadmap({:id, item_id}, project: project, agent: agent),
         {:ok, result} <- run_once(job, item, project, adapter) do
      if terminal_failure?(result) do
        # Revert only on terminal failures (red after repair cap, run crash).
        # Green (even unlanded under :manual) stays in_progress; transient/quota
        # failures keep the job snoozing while task remains in_progress.
        _ = revert_to_pending(item, project)
      end

      to_oban_result(result, job)
    else
      {:error, reason} -> setup_failure_disposition(reason, max(job.attempt || 1, 1))
    end
  end

  # A persisted job outlives the BEAM, so a setup failure that is merely
  # transient at boot (ProjectRegistry not loaded yet, rmap unavailable, a
  # supervisor hiccup) must snooze-and-retry rather than be discarded — that is
  # the restart-resilience Oban is here to provide. Only genuinely malformed
  # job data, which can never succeed on retry, is cancelled.
  @spec setup_failure_disposition(term(), pos_integer()) ::
          {:snooze, pos_integer()} | {:cancel, term()}
  defp setup_failure_disposition(reason, attempt) do
    case reason do
      {:missing_arg, _} -> {:cancel, reason}
      {:invalid_adapter_module, _} -> {:cancel, reason}
      {:unsupported_adapter, _} -> {:cancel, reason}
      _transient -> {:snooze, snooze_seconds(RetryPolicy.new([]), attempt)}
    end
  end

  @doc """
  Maps a terminal `Harness.Run.Result` to Oban's worker return contract.
  """
  @spec to_oban_result(Result.t()) :: Oban.Worker.result()
  def to_oban_result(%Result{} = result), do: result_to_oban(result, 1)

  @doc false
  @spec to_oban_result(Result.t(), Oban.Job.t()) :: Oban.Worker.result()
  def to_oban_result(%Result{} = result, %Oban.Job{attempt: attempt}) do
    result_to_oban(result, max(attempt || 1, 1))
  end

  @spec result_to_oban(Result.t(), pos_integer()) :: Oban.Worker.result()
  defp result_to_oban(%Result{state: :done, reason: :passed}, _attempt), do: :ok

  defp result_to_oban(%Result{state: :failed} = result, attempt) do
    policy = RetryPolicy.new([])

    case FailureClass.classify(result, policy) do
      class when class in [:quota_exhausted, :transient] ->
        {:snooze, snooze_seconds(policy, attempt)}

      :terminal ->
        {:cancel, result.reason}
    end
  end

  @spec run_once(Oban.Job.t(), Item.t(), Project.t(), module()) :: {:ok, Result.t()} | {:error, term()}
  defp run_once(%Oban.Job{} = job, %Item{} = item, %Project{} = project, adapter) do
    checkpoint(job, "run_started")

    # Best-effort claim (run-lifecycle owner per Task 131). Failure logs but does
    # not abort the run; next cron tick's ready/next will skip this task while it
    # is in_progress (or green-unlanded under manual landing_policy).
    _ = claim_in_progress(item, project)

    case start_run(item, project, adapter, run_opts(job, item)) do
      {:ok, run_id, pid} ->
        {:ok, await_run(run_id, Process.monitor(pid), item)}

      {:error, reason} ->
        {:error, {:start_run_failed, reason}}
    end
  end

  @spec await_run(String.t(), reference(), Item.t()) :: Result.t()
  defp await_run(run_id, ref, %Item{} = item) do
    receive do
      {:harness_run, ^run_id, %Result{} = result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, _pid, reason} ->
        %Result{
          run_id: run_id,
          task_id: item.id,
          state: :failed,
          reason: {:run_crashed, reason}
        }
    end
  end

  @spec run_opts(Oban.Job.t(), Item.t()) :: keyword()
  defp run_opts(%Oban.Job{id: id, args: args}, %Item{} = item) when is_integer(id) do
    opts = [batch_id: "oban-job-#{id}", subscriber: self()]

    opts =
      case item.model do
        model when is_binary(model) -> Keyword.put(opts, :requested_model, model)
        _other -> opts
      end

    opts ++ env_opt(args)
  end

  # The dispatch layer (Harness.Batch) persists an optional caller env override
  # into the job args (e.g. %{"ANTHROPIC_API_KEY" => false} to scrub a metered
  # key on Claude OAuth bundles). Thread it into start_run's :env so an
  # Oban-backed bundle honours the same scrubbing as the synchronous dispatch
  # tools. Absent or empty ⇒ no :env opt, preserving prior behaviour.
  @spec env_opt(map()) :: keyword()
  defp env_opt(%{"env" => env}) when is_map(env) and map_size(env) > 0, do: [env: env]
  defp env_opt(_args), do: []

  @spec checkpoint(Oban.Job.t(), String.t()) :: :ok
  defp checkpoint(%Oban.Job{id: id} = job, stage) when is_integer(id) do
    if Process.whereis(Harness.Oban) do
      meta = Map.put(job.meta || %{}, "harness_stage", stage)

      case Oban.update_job(Harness.Oban, job, %{meta: meta}) do
        {:ok, _job} -> :ok
        {:error, _reason} -> :ok
      end
    else
      :ok
    end
  rescue
    _error -> :ok
  end

  defp checkpoint(%Oban.Job{}, _stage), do: :ok

  # Test seam: `:roadmap_ingest` and `:run_starter` Application env keys let
  # tests inject fakes without spinning up RunSupervisor / rmap. Never set
  # either in production config.
  #
  # `:roadmap_mark_in_progress` and `:roadmap_mark_pending` (arity-2 fns of
  # (Item.t(), Project.t())) spy on the best-effort rmap writebacks for the
  # claim-on-start / revert-on-terminal-failure behaviour (Task 131).
  @spec ingest_roadmap(Roadmap.selector(), keyword()) :: {:ok, Item.t()} | {:error, term()}
  defp ingest_roadmap(selector, opts) do
    case Application.get_env(:harness, :roadmap_ingest) do
      fun when is_function(fun, 2) -> fun.(selector, opts)
      _other -> Roadmap.ingest(selector, opts)
    end
  end

  @spec start_run(Item.t(), Project.t(), module(), keyword()) :: {:ok, String.t(), pid()} | {:error, term()}
  defp start_run(%Item{} = item, %Project{} = project, adapter, opts) do
    case Application.get_env(:harness, :run_starter) do
      fun when is_function(fun, 4) -> fun.(item, project, adapter, opts)
      _other -> RunSupervisor.start_run(item, project, adapter, opts)
    end
  end

  # Best-effort claim + revert seams (default to real Roadmap calls + log).
  @spec claim_in_progress(Item.t(), Project.t()) :: :ok
  defp claim_in_progress(%Item{} = item, %Project{} = project) do
    case Application.get_env(:harness, :roadmap_mark_in_progress) do
      fun when is_function(fun, 2) -> fun.(item, project)
      _ -> do_mark_in_progress(item, project)
    end
  end

  @spec revert_to_pending(Item.t(), Project.t()) :: :ok
  defp revert_to_pending(%Item{} = item, %Project{} = project) do
    case Application.get_env(:harness, :roadmap_mark_pending) do
      fun when is_function(fun, 2) -> fun.(item, project)
      _ -> do_mark_pending(item, project)
    end
  end

  @spec do_mark_in_progress(Item.t(), Project.t()) :: :ok
  defp do_mark_in_progress(%Item{} = item, %Project{} = project) do
    case Roadmap.mark_in_progress(item, root: project.roadmap_path) do
      {:ok, _output} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "harness run: failed to mark task #{item.id} in_progress (best-effort; continuing): #{inspect(reason)}"
        )

        :ok
    end
  end

  @spec do_mark_pending(Item.t(), Project.t()) :: :ok
  defp do_mark_pending(%Item{} = item, %Project{} = project) do
    case Roadmap.mark_pending(item, root: project.roadmap_path) do
      {:ok, _output} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "harness run: failed to mark task #{item.id} pending after terminal failure (best-effort): #{inspect(reason)}"
        )

        :ok
    end
  end

  @spec terminal_failure?(Result.t()) :: boolean()
  defp terminal_failure?(%Result{state: :failed} = result) do
    FailureClass.classify(result, RetryPolicy.new([])) == :terminal
  end

  defp terminal_failure?(_), do: false

  @spec fetch_arg(args(), String.t()) :: {:ok, String.t()} | {:error, {:missing_arg, String.t()}}
  defp fetch_arg(args, key) do
    case Map.fetch(args, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _other -> {:error, {:missing_arg, key}}
    end
  end

  @spec adapter_module(String.t()) :: {:ok, module()} | {:error, {:invalid_adapter_module, String.t()}}
  defp adapter_module(name) when is_binary(name) do
    module = String.to_existing_atom(name)

    if Code.ensure_loaded?(module) do
      {:ok, module}
    else
      {:error, {:invalid_adapter_module, name}}
    end
  rescue
    ArgumentError -> {:error, {:invalid_adapter_module, name}}
  end

  @spec agent_for_adapter(module()) :: {:ok, :claude | :codex | :cursor} | {:error, {:unsupported_adapter, module()}}
  defp agent_for_adapter(adapter) do
    case AgentRegistry.agent_for_module(adapter) do
      {:ok, agent} when agent in [:claude, :codex, :cursor] -> {:ok, agent}
      _other -> {:error, {:unsupported_adapter, adapter}}
    end
  end

  @spec snooze_seconds(RetryPolicy.t(), pos_integer()) :: pos_integer()
  defp snooze_seconds(%RetryPolicy{} = policy, attempt) when is_integer(attempt) and attempt > 0 do
    policy |> RetryPolicy.backoff_ms(attempt) |> div_ceil(1_000) |> max(1)
  end

  @spec div_ceil(non_neg_integer(), pos_integer()) :: non_neg_integer()
  defp div_ceil(value, divisor), do: div(value + divisor - 1, divisor)
end
