defmodule Harness.Oban.QueueBootstrap do
  @moduledoc false

  use Task

  @doc false
  @spec start_link(term()) :: {:ok, pid()}
  def start_link(init_arg \\ []) do
    Task.start_link(__MODULE__, :run, [init_arg])
  end

  @doc false
  @spec run(term()) :: :ok
  def run(_init_arg) do
    Harness.Oban.bootstrap_project_queues()
    :ok
  end
end
