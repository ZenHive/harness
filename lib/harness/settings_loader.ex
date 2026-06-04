defmodule Harness.SettingsLoader do
  @moduledoc false

  alias Harness.Agent.Settings, as: AgentSettings
  alias Harness.Cron.Settings, as: CronSettings
  alias Harness.Landing.Settings, as: LandingSettings

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [arg]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc false
  @spec start_link(term()) :: :ignore
  def start_link(_arg) do
    load_into_env()
    :ignore
  end

  @doc false
  @spec load_into_env() :: :ok
  def load_into_env do
    CronSettings.load_into_env()
    AgentSettings.load_into_env()
    LandingSettings.load_into_env()
    :ok
  end
end
