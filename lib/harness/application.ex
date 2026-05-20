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

  # The boot-time worktree orphan sweep runs as a transient child: it does its
  # job once and exits. Disabled in the test env (see config/config.exs).
  @spec children() :: [module()]
  defp children do
    worktree = Application.get_env(:harness, :worktree, [])

    if Keyword.get(worktree, :sweep_on_boot, true) do
      [Harness.Worktree.Sweeper]
    else
      []
    end
  end
end
