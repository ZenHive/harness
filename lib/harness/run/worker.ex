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

    case start_run(item, project, adapter, run_opts(job)) do
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

  @spec run_opts(Oban.Job.t()) :: keyword()
  defp run_opts(%Oban.Job{id: id}) when is_integer(id) do
    [batch_id: "oban-job-#{id}", subscriber: self()]
  end

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
