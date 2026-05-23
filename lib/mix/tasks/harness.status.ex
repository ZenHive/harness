defmodule Mix.Tasks.Harness.Status do
  @shortdoc "Shows a human-readable view of harness run fleet state"

  @moduledoc """
  Prints a glanceable fleet status: in-flight, repairing, green, and red runs,
  plus any agents marked unavailable.

      mix harness.status
  """

  use Mix.Task

  alias Harness.StatusView

  @impl Mix.Task
  @spec run([term()]) :: :ok
  def run(_args) do
    Mix.Task.run("app.start")
    StatusView.snapshot() |> StatusView.render() |> IO.puts()
    :ok
  end
end
