defmodule Mix.Tasks.Harness.Status do
  @shortdoc "Shows a human-readable view of harness run fleet state"

  @moduledoc """
  Prints a glanceable fleet status: in-flight, repairing, green, and red runs,
  plus any agents marked unavailable.

      mix harness.status

  ## Same-BEAM only

  This task reads `Harness.Run.Supervisor` and `Harness.AgentRegistry` directly,
  so it only sees runs and adapters registered in the current BEAM. A separate
  `mix harness.status` invocation in another terminal starts its own
  application and sees an empty fleet. Run it from inside the
  `iex -S mix`/`iex -S mix tidewave` session that owns the dispatch loop, or
  invoke `Harness.StatusView.snapshot/0` and `render/1` directly from a remote
  shell attached to the running node.
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
