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

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {Harness.Dashboard.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  # Oban Web's scope must precede the LiveView scope so `/harness/oban`
  # routes to Oban Web rather than the dashboard LiveView.
  scope "/" do
    pipe_through(:browser)

    oban_dashboard("/harness/oban", oban_name: Harness.Oban)
  end

  scope "/", Harness.Dashboard do
    pipe_through(:browser)

    live("/harness", Live, :index, as: :dashboard)
    live("/harness/runs/:run_id", Live, :show, as: :dashboard)
  end
end
