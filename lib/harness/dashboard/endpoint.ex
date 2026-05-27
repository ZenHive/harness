defmodule Harness.Dashboard.Endpoint do
  @moduledoc """
  Phoenix endpoint that hosts the standalone harness dashboard (Task 50).

  Started by `Harness.Application` only when `:dashboard, enabled: true` AND
  Bandit is loaded — mountable consumers leave `enabled: false` and route
  `Harness.Dashboard.Live` plus `oban_dashboard "/harness/oban"` into their own
  Phoenix endpoint instead. The endpoint binds 127.0.0.1 by default (port
  configured under the `:harness, :dashboard` key; runtime override via
  `HARNESS_DASHBOARD_PORT`) and uses the shared `Harness.PubSub` bus so the
  per-run transcript broadcast (also Task 50) is reachable from the LiveView.
  """

  use Phoenix.Endpoint, otp_app: :harness

  @session_options [
    store: :cookie,
    key: "_harness_dashboard_key",
    signing_salt: "harness-dashboard-session-salt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:harness, :dashboard, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(Harness.Dashboard.Router)
end
