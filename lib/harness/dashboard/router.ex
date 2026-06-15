defmodule Harness.Dashboard.Router do
  @moduledoc """
  Router for the standalone harness dashboard endpoint (Task 50).

  Mounts the LiveView at `/harness/*path` and the embedded Oban Web queue view
  at `/harness/oban`. Mountable consumers replicate the same two routes in
  their own router (see `Harness.Dashboard` for the snippet).
  """

  use Phoenix.Router

  import Oban.Web.Router
  import Phoenix.LiveView.Router

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
  forward("/harness/mcp", Anubis.Server.Transport.StreamableHTTP.Plug,
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
    live("/harness/kpi", KPILive, :index, as: :dashboard_kpi)
    live("/harness/compare", CompareLive, :index, as: :dashboard_compare)
    live("/harness/compare/:comparison_id", CompareLive, :show, as: :dashboard_compare)
    live("/harness/runs/:run_id", Live, :show, as: :dashboard)
    live("/harness/chat", ChatLive, :index, as: :dashboard_chat)
    live("/harness/chat/:session_id", ChatLive, :show, as: :dashboard_chat)
  end
end
