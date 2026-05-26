defmodule Harness.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @spec start(Application.start_type(), term()) :: {:ok, pid()} | {:error, term()}
  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: Harness.Supervisor]
    Supervisor.start_link(children(), opts)
  end

  # The run layer: a Registry for run-id -> pid lookup, a Task.Supervisor that
  # parents every per-run async step, and the DynamicSupervisor under which each
  # `Harness.Run` gen_statem starts crash-isolated from its siblings. The
  # boot-time worktree orphan sweep runs last as a transient child — it does its
  # job once and exits. The sweep is disabled in the test env (see
  # config/config.exs); the run-layer children are always on.
  @spec children() :: [Supervisor.child_spec() | {module(), term()} | module()]
  defp children do
    [
      {Registry, keys: :unique, name: Harness.Run.Registry},
      Harness.ProjectRegistry,
      Harness.AgentRegistry
    ] ++
      repo() ++
      [
        {Task.Supervisor, name: Harness.Run.TaskSupervisor},
        Harness.Run.Supervisor
      ] ++ oban() ++ sweeper()
  end

  @spec repo() :: [module()]
  defp repo do
    if Application.get_env(:harness, :repo_enabled, true) do
      [Harness.Repo]
    else
      []
    end
  end

  @spec oban() :: [module()]
  defp oban do
    if Application.get_env(:harness, :oban_enabled, true) do
      [Harness.Oban]
    else
      []
    end
  end

  @spec sweeper() :: [module()]
  defp sweeper do
    worktree = Application.get_env(:harness, :worktree, [])

    if Keyword.get(worktree, :sweep_on_boot, true) do
      [Harness.Worktree.Sweeper]
    else
      []
    end
  end
end
