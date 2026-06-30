defmodule Harness.Oban.QueueBootstrap do
  @moduledoc false

  use Task

  require Logger

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
  rescue
    # Postgres may not be up when this one-shot Task fires at boot; a raised
    # bootstrap shouldn't vanish silently with the Task's exit. Log and let the
    # supervisor restart it (or proceed without per-project queues). Narrowed to
    # infra-not-ready exceptions so a genuine code bug still crashes the Task.
    error in [RuntimeError, DBConnection.ConnectionError, DBConnection.OwnershipError, Postgrex.Error, ArgumentError] ->
      Logger.warning("harness queue bootstrap failed: #{Exception.message(error)}")
      :ok
  end
end
