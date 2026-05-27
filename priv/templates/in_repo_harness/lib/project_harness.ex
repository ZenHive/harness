defmodule ProjectHarness.Application do
  use Application

  @impl true
  def start(_type, _args) do
    {:ok, _} = Application.ensure_all_started(:harness)
    Supervisor.start_link([], strategy: :one_for_one, name: ProjectHarness.Supervisor)
  end
end
