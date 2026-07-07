defmodule Harness.Run.Actions.Recovery do
  @moduledoc false

  import Harness.Run.Actions.Control, only: [cancel_task: 1, terminate_recovery: 1]
  import Harness.Run.Actions.Reviewing, only: [transcript_tail: 1]
  import Harness.Run.Actions.Timeouts, only: [reviewer_idle_timeout: 1]
  import Harness.Run.Actions.Worktree, only: [agent_rule_content: 1, in_run_env: 1, put_opt: 3, run_driver: 4]

  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Outcome
  alias Harness.Git
  alias Harness.Project
  alias Harness.Run.Recovery
  alias Harness.Run.Result

  require Logger

  @type data :: map()
  @type handler_result :: term()
  @doc false
  @spec clear_recovery_run(data()) :: data()
  def clear_recovery_run(data), do: %{data | recovery_run: nil}

  @doc false
  @spec recover_checkout_pollution(data(), Result.reason()) :: handler_result()
  def recover_checkout_pollution(%{recovery_attempts: attempts, recovery_budget: budget} = data, reason)
      when attempts < budget do
    {:next_state, :recovering, %{data | reason: reason, recovery_reason: reason}}
  end

  def recover_checkout_pollution(data, reason), do: {:next_state, :failed, %{data | reason: reason}}

  @doc false
  @spec fail_recovery_dead(data(), String.t()) :: handler_result()
  def fail_recovery_dead(data, report) do
    Logger.info("harness run: recovery declared dead for #{data.run_id}: #{report}")
    terminate_recovery(data)
    cancel_task(data.task)

    {:next_state, :failed,
     %{
       data
       | task: nil,
         recovery_run: nil,
         recovery_outcome: :dead,
         recovery_repaired: nil,
         reason: data.recovery_reason
     }}
  end

  @doc false
  @spec settle_recovery(data(), {:ok, Recovery.t()} | {:error, Recovery.error()}) :: handler_result()
  def settle_recovery(data, {:ok, %Recovery{outcome: :repaired} = recovery}) do
    Logger.info("harness run: recovery repaired #{data.run_id}; resuming through commit + review")

    {:next_state, :committing,
     %{
       data
       | recovery_outcome: :repaired,
         recovery_repaired: recovery.repaired,
         reason: nil,
         recovery_reason: nil
     }}
  end

  def settle_recovery(data, {:ok, %Recovery{outcome: :dead} = recovery}) do
    fail_recovery_dead(%{data | recovery_repaired: recovery.repaired}, recovery.report)
  end

  def settle_recovery(data, {:error, reason}) do
    fail_recovery_dead(data, "Recovery artifact is malformed or missing: #{inspect(reason)}")
  end

  @doc false
  @spec run_recovery(data(), pid()) ::
          {:ok, %{outcome: Outcome.t(), recovery: {:ok, Recovery.t()} | {:error, Recovery.error()}}}
          | {:error, term()}
  def run_recovery(%{recovery_adapter: adapter} = data, parent) when is_atom(adapter) do
    with {:ok, %Outcome{} = outcome} <-
           run_driver(data, adapter, recovery_invocation(data), recovery_driver_opts(data, parent)) do
      {:ok, %{outcome: outcome, recovery: Recovery.read(data.worktree.path)}}
    end
  end

  @doc false
  @spec recovery_invocation(data()) :: Invocation.t()
  def recovery_invocation(data) do
    repo_path = Project.repo_path(data.project)

    %Invocation{
      prompt: Recovery.prompt(recovery_context(data, repo_path)),
      cwd: data.worktree.path,
      log_tag: "#{data.item.id}-recovery",
      model: data.requested_model,
      rule_content: agent_rule_content(data.project),
      permission_mode: :autonomous,
      adapter_opts: data.reviewer_adapter_opts,
      env: Map.put(in_run_env(data), "HARNESS_RECOVERY_REPO", repo_path)
    }
  end

  @doc false
  @spec recovery_context(data(), String.t()) :: Recovery.context()
  def recovery_context(data, repo_path) do
    %{
      reason: data.recovery_reason,
      repo_path: repo_path,
      git_status: git_status(data.worktree.path),
      transcript_tail: transcript_tail(data.transcript),
      check_output: recovery_check_output(data.recovery_reason, repo_path)
    }
  end

  @doc false
  @spec recovery_check_output(Result.reason() | nil, String.t()) :: String.t()
  def recovery_check_output({:checkout_polluted, status}, _repo_path) when is_binary(status), do: status
  def recovery_check_output(_reason, repo_path), do: git_status(repo_path)

  @doc false
  @spec git_status(String.t()) :: String.t()
  def git_status(path) do
    case Git.run(["status", "--porcelain"], path) do
      {:ok, status} -> status
      {:error, reason} -> "git status failed: #{inspect(reason)}"
    end
  end

  @doc false
  @spec recovery_driver_opts(data(), pid()) :: keyword()
  def recovery_driver_opts(data, parent) do
    [
      on_spawn: fn run -> send(parent, {:recovery_handle, run}) end,
      on_output: fn chunk -> send(parent, {:transcript_chunk, chunk}) end
    ]
    |> put_opt(:total_timeout, data.total_timeout)
    |> put_opt(:idle_timeout, reviewer_idle_timeout(data.idle_timeout))
    |> put_opt(:progress_timeout, data.progress_timeout)
  end
end
