defmodule Harness.Test.InsightsScriptedWitness do
  @moduledoc false
  @behaviour Harness.Insights.Witness

  @impl true
  @spec observe(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def observe(context, model) do
    Application.fetch_env!(:harness, :insights_script).(context, model)
  end
end
