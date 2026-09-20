defmodule Harness.Dispatch.Compare do
  @moduledoc "Cross-adapter evaluation of an identical roadmap task."

  alias Harness.Batch.AgentEvaluation
  alias Harness.Batch.AgentEvaluation.Comparison
  alias Harness.Dispatch.Presentation
  alias Harness.Dispatch.Resolution
  alias Harness.Dispatch.Submission
  alias Harness.Roadmap

  @spec compare(String.t(), String.t(), [String.t()]) :: {:ok, map()} | {:error, Harness.Dispatch.error()}

  @spec compare(String.t(), String.t(), [String.t()], boolean() | map()) ::
          {:ok, map()} | {:error, Harness.Dispatch.error()}

  @spec compare(String.t(), String.t(), [String.t()], map(), boolean()) ::
          {:ok, map()} | {:error, Harness.Dispatch.error()}
  @doc false
  def compare(project_name, task, adapters, models, scrub_anthropic_key)
      when is_binary(project_name) and is_binary(task) and is_list(adapters) and is_map(models) and
             is_boolean(scrub_anthropic_key) do
    with {:ok, modules} <- resolve_adapter_modules(adapters),
         {:ok, project} <- Resolution.lookup_project(project_name),
         # Render once, for claude, on purpose: every adapter must run the
         # identical prompt for the A/B comparison to be fair — this is not the
         # old non-delegatable two-step (rmap now renders natively for all six).
         {:ok, item} <- Roadmap.ingest(Resolution.selector(task), project: project, agent: :claude),
         {:ok, %Comparison{} = comparison} <-
           AgentEvaluation.compare(item, project, modules,
             models: models,
             env: Submission.scrub_env(scrub_anthropic_key)
           ) do
      {:ok, Presentation.summarize_comparison(comparison)}
    end
  end

  @doc false
  def compare(project_name, task, adapters), do: compare(project_name, task, adapters, %{}, true)

  @doc false
  def compare(project_name, task, adapters, scrub_anthropic_key) when is_boolean(scrub_anthropic_key) do
    compare(project_name, task, adapters, %{}, scrub_anthropic_key)
  end

  @doc false
  def compare(project_name, task, adapters, models) when is_map(models) do
    compare(project_name, task, adapters, models, true)
  end

  # Resolve a non-empty list of executor names to adapter modules for a same-task
  # A/B run. All six executors are valid here — run_pinned takes modules directly.
  @spec resolve_adapter_modules([String.t()]) :: {:ok, [module()]} | {:error, Harness.Dispatch.error()}
  defp resolve_adapter_modules([]), do: {:error, :no_adapters}

  defp resolve_adapter_modules(adapters) do
    adapters
    |> Enum.reduce_while({:ok, []}, fn adapter, {:ok, modules} ->
      case Resolution.resolve_adapter(adapter) do
        {:ok, {module, _render_agent}} -> {:cont, {:ok, [module | modules]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, modules} -> {:ok, Enum.reverse(modules)}
      {:error, _reason} = error -> error
    end
  end
end
