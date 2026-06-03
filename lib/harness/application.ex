defmodule Harness.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Harness.Agent.Settings, as: AgentSettings
  alias Harness.Cron.Settings
  alias Harness.Landing.Settings, as: LandingSettings

  @spec start(Application.start_type(), term()) :: {:ok, pid()} | {:error, term()}
  @impl true
  def start(_type, _args) do
    # Seed the persisted operator switches into app env before any child boots,
    # so the dispatch paths reflect the operator's last choice from t=0 rather
    # than compile-time defaults: cron autonomy (Tasks 109/110, read by Oban's
    # RoadmapPoller) and per-agent enable/disable (read by AgentRegistry.select/2).
    Settings.load_into_env()
    AgentSettings.load_into_env()
    LandingSettings.load_into_env()

    opts = [strategy: :one_for_one, name: Harness.Supervisor]
    Supervisor.start_link(children(), opts)
  end

  # The run layer: a Registry for run-id -> pid lookup, a Task.Supervisor that
  # parents every per-run async step, and the DynamicSupervisor under which each
  # `Harness.Run` gen_statem starts crash-isolated from its siblings. The
  # boot-time worktree orphan sweep runs last as a transient child — it does its
  # job once and exits. The sweep is disabled in the test env (see
  # config/config.exs); the run-layer children are always on. The dashboard
  # endpoint (Task 50) supervises last — Phoenix.PubSub must already be up so
  # the Driver loop's transcript broadcast has a working bus whether or not the
  # Endpoint is started in the current environment.
  @spec children() :: [Supervisor.child_spec() | {module(), term()} | module()]
  defp children do
    [
      {Registry, keys: :unique, name: Harness.Run.Registry},
      {Registry, keys: :unique, name: Harness.Chat.Registry},
      Harness.AgentRegistry,
      {Phoenix.PubSub, name: Harness.PubSub},
      Harness.Chat.Supervisor,
      {Task.Supervisor, name: Harness.Chat.TaskSupervisor}
    ] ++
      repo() ++
      [
        Harness.ProjectRegistry,
        {Task.Supervisor, name: Harness.Run.TaskSupervisor}
      ] ++ reaper() ++ [Harness.Run.Supervisor] ++ oban() ++ sweeper() ++ dashboard() ++ mcp_server()
  end

  # Same-BEAM crash reaper (Task 185): reclaims a worktree+branch a run leaks
  # when it crashes before settling (the boot Sweeper is the cross-restart
  # backstop; this closes the within-node gap). Started before Run.Supervisor so
  # every run can track itself the moment its worktree activates. Disabled in the
  # test env (config/config.exs) — Reaper tests start it explicitly.
  @spec reaper() :: [module()]
  defp reaper do
    worktree = Application.get_env(:harness, :worktree, [])

    if Keyword.get(worktree, :reap_on_crash, true) do
      [Harness.Worktree.Reaper]
    else
      []
    end
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

  # Standalone Phoenix endpoint for the LiveView dashboard (Task 50). Mountable
  # consumers leave `:dashboard, enabled` false and route the LiveView into
  # their own endpoint instead. `Code.ensure_loaded?/1` keeps the start
  # contingent on Bandit being on the consumer's path: harness declares Bandit
  # `optional: true` so a mountable consumer is not forced into a second HTTP
  # server, and a missing Bandit therefore drops the endpoint with a clear log
  # message rather than crashing the application.
  @spec dashboard() :: [module()]
  defp dashboard do
    dashboard_config = Application.get_env(:harness, :dashboard, [])
    enabled? = Keyword.get(dashboard_config, :enabled, false)

    cond do
      not enabled? ->
        []

      not Code.ensure_loaded?(Bandit) ->
        require Logger

        Logger.info(
          "Harness.Dashboard.Endpoint not started: :bandit is not in the consumer's dep stack. " <>
            "Add `{:bandit, \"~> 1.11\"}` to use the standalone dashboard, or mount " <>
            "`Harness.Dashboard.Live` and `oban_dashboard` into your own Phoenix router."
        )

        []

      true ->
        [Harness.Dashboard.Endpoint]
    end
  end

  # Real MCP server (Task 79 rework) — JSON-RPC 2.0 over Streamable HTTP via
  # `anubis_mcp`. Gated on `:dashboard, :enabled` because the Streamable HTTP
  # transport is meaningless without a Phoenix endpoint forwarding to it.
  #
  # `start: true` is load-bearing (Task 83). Anubis's `should_start?/1` for the
  # streamable_http transport falls through to `:phoenix, :serve_endpoints` when
  # the opt is absent, which is `false` under `iex -S mix` (we are not a
  # `phx.server` app — the dashboard is one opt-in surface among many, see the
  # mountable-consumer story in CLAUDE.md). Without this, the supervisor
  # returned `:ignore`, no `:persistent_term` was stored, and every MCP request
  # crashed with `ArgumentError` on `:persistent_term.get/1` (logged as
  # `:badarg`). The per-endpoint `server: true` in `config :harness, Endpoint`
  # already starts the dashboard Bandit regardless of the global Phoenix flag;
  # this opt keeps Anubis aligned with that reality.
  @spec mcp_server() :: [{module(), keyword()}]
  defp mcp_server do
    dashboard_config = Application.get_env(:harness, :dashboard, [])

    if Keyword.get(dashboard_config, :enabled, false) do
      [{Harness.Dashboard.MCPServer, transport: {:streamable_http, start: true}}]
    else
      []
    end
  end
end
