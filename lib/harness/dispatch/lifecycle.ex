defmodule Harness.Dispatch.Lifecycle do
  @moduledoc "Operator run control and recovery of retained attempts."

  alias Harness.AgentRegistry
  alias Harness.Dispatch.Decision
  alias Harness.Dispatch.Presentation
  alias Harness.Dispatch.Resolution
  alias Harness.Dispatch.Submission
  alias Harness.Lander
  alias Harness.Project
  alias Harness.ResultStore
  alias Harness.Roadmap
  alias Harness.Roadmap.Item
  alias Harness.Run
  alias Harness.Run.LogRecord
  alias Harness.Run.Worker, as: RunWorker

  @recommended_adapter "recommend"

  @spec cancel(String.t()) :: {:ok, %{run_id: String.t(), cancelled: true}}
  @doc false
  def cancel(run_id) when is_binary(run_id) do
    :ok = Run.cancel(run_id)
    {:ok, %{run_id: run_id, cancelled: true}}
  end

  @spec hold(String.t(), boolean()) ::
          {:ok, %{run_id: String.t(), held: true, interrupt: boolean()}}
          | {:error, :terminal | :invalid_state | :not_found}

  @doc false
  def hold(run_id, interrupt \\ false) when is_binary(run_id) and is_boolean(interrupt) do
    case Run.hold(run_id, interrupt) do
      :ok -> {:ok, %{run_id: run_id, held: true, interrupt: interrupt}}
      {:error, _reason} = error -> error
    end
  end

  @spec steer(String.t(), String.t()) ::
          {:ok, %{run_id: String.t(), steered: true}}
          | {:error, :resume_unsupported | :not_found}

  @doc false
  def steer(run_id, text) when is_binary(run_id) and is_binary(text) do
    case Run.steer(run_id, text) do
      :ok -> {:ok, %{run_id: run_id, steered: true}}
      {:error, _reason} = error -> error
    end
  end

  @spec resume(String.t()) ::
          {:ok, %{run_id: String.t(), resumed: true}} | {:error, :not_held | :not_found}
  @doc false
  def resume(run_id) when is_binary(run_id) do
    case Run.resume(run_id) do
      :ok -> {:ok, %{run_id: run_id, resumed: true}}
      {:error, _reason} = error -> error
    end
  end

  @spec resume_failed(String.t(), boolean()) ::
          {:ok, %{run_id: String.t(), resumed_from: String.t(), agent: atom() | nil}}
          | {:error, Harness.Dispatch.error()}

  @doc false
  def resume_failed(run_id, escalate \\ false) when is_binary(run_id) and is_boolean(escalate) do
    with {:ok, record} <- load_failed_record(run_id),
         {:ok, {project, item, adapter_module}} <-
           Resolution.resolve_and_ingest(record.project_name, record.task_id, resume_adapter(record, escalate)),
         {:ok, decision} <-
           Decision.recovery(project, %{item | model: Resolution.effective_model(item, item.agent)}, "resume", run_id),
         {:ok, new_run_id, _job} <-
           RunWorker.enqueue(project, item, adapter_module, recovery_enqueue_opts(decision)) do
      {:ok, %{run_id: new_run_id, resumed_from: run_id, agent: item.agent}}
    end
  end

  @spec rereview(String.t()) ::
          {:ok, %{run_id: String.t(), rereviewed_from: String.t(), agent: atom() | nil}}
          | {:error, Harness.Dispatch.error()}

  @doc false
  def rereview(run_id) when is_binary(run_id) do
    with {:ok, record} <- ResultStore.fetch_run_record(run_id),
         {:ok, project} <- lookup_record_project(record),
         {:ok, item} <- Roadmap.ingest(Resolution.selector(record.task_id), project: project, agent: record_agent(record)),
         {:ok, adapter} <- AgentRegistry.delegatable_module_for_agent(item.agent),
         {:ok, decision} <-
           Decision.recovery(project, %{item | model: Resolution.effective_model(item, item.agent)}, "rereview", run_id),
         {:ok, new_run_id, _job} <-
           RunWorker.enqueue(project, item, adapter, recovery_enqueue_opts(decision)) do
      {:ok, %{run_id: new_run_id, rereviewed_from: run_id, agent: item.agent}}
    end
  end

  @spec recovery_enqueue_opts(map()) :: keyword()
  defp recovery_enqueue_opts(decision) do
    [
      dispatch_decision: decision,
      requested_model: decision["model"],
      env: %{"ANTHROPIC_API_KEY" => false, "OPENAI_API_KEY" => false}
    ]
  end

  @spec load_failed_record(String.t()) ::
          {:ok, LogRecord.t()} | {:error, :not_found | :not_failed | term()}
  defp load_failed_record(run_id) do
    case ResultStore.list_run_records(run_id: run_id) do
      {:ok, [%LogRecord{state: :failed} = record | _]} -> {:ok, record}
      {:ok, [%LogRecord{} | _]} -> {:error, :not_failed}
      {:ok, []} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec resume_adapter(LogRecord.t(), boolean()) :: String.t()
  @doc false
  def resume_adapter(_record, true), do: @recommended_adapter

  @doc false
  def resume_adapter(%LogRecord{agent: agent}, false) when is_atom(agent) and not is_nil(agent), do: Atom.to_string(agent)

  @doc false
  def resume_adapter(%LogRecord{}, false), do: @recommended_adapter

  @spec resume_item(Item.t(), LogRecord.t()) :: Item.t()
  @doc false
  def resume_item(%Item{} = item, %LogRecord{} = record) do
    %{item | prompt: item.prompt <> "\n\n" <> Presentation.prior_attempt_section(record)}
  end

  @spec resume_opts(Item.t(), String.t()) :: keyword()
  @doc false
  def resume_opts(%Item{} = item, old_run_id) do
    item
    |> Submission.run_start_opts(nil, true)
    |> Keyword.put(:base_ref, "harness/" <> old_run_id)
  end

  @spec rereview_opts(Item.t(), LogRecord.t(), String.t()) :: keyword()
  @doc false
  def rereview_opts(%Item{} = item, %LogRecord{} = record, old_run_id) do
    item
    |> Submission.run_start_opts(nil, true)
    |> Keyword.put(:base_ref, "harness/" <> old_run_id)
    |> Keyword.put(:review_only?, true)
    |> Keyword.put(:review_only_agent_diff_size, record.agent_diff_size)
  end

  @spec lookup_record_project(LogRecord.t()) :: {:ok, Project.t()} | {:error, {:unknown_project, String.t() | nil}}
  defp lookup_record_project(%LogRecord{project_name: project_name}) when is_binary(project_name) do
    Resolution.lookup_project(project_name)
  end

  defp lookup_record_project(%LogRecord{project_name: project_name}), do: {:error, {:unknown_project, project_name}}

  @spec record_agent(LogRecord.t()) :: atom()
  defp record_agent(%LogRecord{agent: agent}) when is_atom(agent) and not is_nil(agent), do: agent

  defp record_agent(%LogRecord{}), do: :claude

  @spec reland(String.t()) ::
          {:ok, %{run_id: String.t(), task_id: String.t()}} | {:error, Harness.Dispatch.error()}
  @doc false
  def reland(run_id) when is_binary(run_id) do
    Lander.enqueue(run_id)
  end
end
