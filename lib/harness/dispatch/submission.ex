defmodule Harness.Dispatch.Submission do
  @moduledoc "Roadmap task submission and run start options."

  alias Harness.Dispatch.Resolution
  alias Harness.Roadmap.Item
  alias Harness.Run.Worker, as: RunWorker

  @recommended_adapter "recommend"

  @spec task(String.t(), String.t(), String.t(), boolean()) ::
          {:ok, %{run_id: String.t()}} | {:error, Harness.Dispatch.error()}
  @doc false
  def task(project_name, task, adapter \\ @recommended_adapter, scrub_anthropic_key \\ true)
      when is_binary(project_name) and is_binary(task) and is_binary(adapter) and is_boolean(scrub_anthropic_key) do
    with {:ok, run_id} <- enqueue_start(project_name, task, adapter, scrub_anthropic_key) do
      {:ok, %{run_id: run_id}}
    end
  end

  # Restart-resilient fire-and-forget path for `task/4`: resolve and render the
  # item now, then persist the worker job before returning the run id. The worker
  # re-ingests by task id and starts the run with the stored id when Oban executes
  # the job.
  @spec enqueue_start(String.t(), String.t(), String.t(), boolean()) ::
          {:ok, String.t()} | {:error, Harness.Dispatch.error()}
  @doc false
  def enqueue_start(project_name, task, adapter, scrub_anthropic_key) do
    with {:ok, {project, item, adapter_module}} <- Resolution.resolve_and_ingest(project_name, task, adapter),
         {:ok, run_id, _job} <-
           RunWorker.enqueue(project, item, adapter_module, run_start_opts(item, nil, scrub_anthropic_key)) do
      {:ok, run_id}
    end
  end

  @spec start_opts(pid() | nil, boolean()) :: keyword()
  @doc false
  def start_opts(subscriber, scrub_anthropic_key) do
    [subscriber: subscriber, env: scrub_env(scrub_anthropic_key)]
  end

  @spec run_start_opts(Item.t(), pid() | nil, boolean()) :: keyword()
  @doc false
  def run_start_opts(%Item{} = item, subscriber, scrub_anthropic_key) do
    item
    |> Map.get(:model)
    |> case do
      model when is_binary(model) ->
        subscriber
        |> start_opts(scrub_anthropic_key)
        |> Keyword.put(:requested_model, model)

      _other ->
        start_opts(subscriber, scrub_anthropic_key)
    end
  end

  @spec scrub_env(boolean()) :: %{optional(String.t()) => false}
  @doc false
  def scrub_env(true), do: %{"ANTHROPIC_API_KEY" => false}

  @doc false
  def scrub_env(false), do: %{}
end
