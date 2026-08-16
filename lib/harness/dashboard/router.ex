defmodule Harness.Dashboard.Router do
  @moduledoc """
  Router for the standalone harness dashboard endpoint (Task 50).

  Mounts the native MCP server at `/harness/mcp`, the embedded Oban Web queue
  view at `/harness/oban`, and the LiveViews under `/harness`. Mountable
  consumers reproduce the required routes in their own router.

  This router deliberately has no authentication or authorization plug; its
  routes assume the standalone endpoint's default loopback bind. Consumers
  mounting the routes in a non-loopback or public endpoint must protect both
  the browser pipeline and the separate `/harness/mcp` forward with their own
  authentication and authorization plug. Protecting only the browser pipeline
  leaves MCP control unauthenticated.
  """

  use Phoenix.Router

  import Oban.Web.Router
  import Phoenix.LiveView.Router

  alias Harness.Dashboard.MCPPlug
  alias Harness.Dashboard.MCPServer

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {Harness.Dashboard.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  # MCP endpoint (Task 79 rework): real JSON-RPC 2.0 over Streamable HTTP via
  # `anubis_mcp`. Tools come from `Harness.Manifest` — see
  # `Harness.Dashboard.MCPServer` for the dispatch wiring.
  forward("/harness/mcp", MCPPlug,
    server: MCPServer,
    request_timeout: MCPServer.request_timeout_ms()
  )

  # Oban Web's scope must precede the LiveView scope so `/harness/oban`
  # routes to Oban Web rather than the dashboard LiveView.
  scope "/" do
    pipe_through(:browser)

    oban_dashboard("/harness/oban", oban_name: Harness.Oban)
  end

  scope "/", Harness.Dashboard do
    pipe_through(:browser)

    live("/harness", Live, :index, as: :dashboard)
    live("/harness/roadmap", RoadmapLive, :index, as: :dashboard_roadmap)
    live("/harness/settings", SettingsLive, :index, as: :dashboard_settings)
    live("/harness/kpi/agents", KPILive, :agents, as: :dashboard_kpi_agents)
    live("/harness/kpi", KPILive, :index, as: :dashboard_kpi)
    live("/harness/compare", CompareLive, :index, as: :dashboard_compare)
    live("/harness/compare/:comparison_id", CompareLive, :show, as: :dashboard_compare)
    live("/harness/deps", DepFreshnessLive, :index, as: :dashboard_deps)
    live("/harness/deps/:name", DepFreshnessLive, :show, as: :dashboard_deps)
    live("/harness/health", SuiteHealthLive, :index, as: :dashboard_health)
    live("/harness/health/:name", SuiteHealthLive, :show, as: :dashboard_health)
    live("/harness/projects", Live.ProjectExplorer, :index, as: :dashboard_projects)
    live("/harness/projects/explore", Live.ProjectExplorer, :index, as: :dashboard_project_explorer_index)
    live("/harness/projects/:name/explore", Live.ProjectExplorer, :show, as: :dashboard_project_explorer)
    live("/harness/runs/:run_id", Live, :show, as: :dashboard)
    live("/harness/chat", ChatLive, :index, as: :dashboard_chat)
    live("/harness/chat/:session_id", ChatLive, :show, as: :dashboard_chat)
  end
end
