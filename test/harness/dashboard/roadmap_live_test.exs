defmodule Harness.Dashboard.RoadmapLiveTest do
  @moduledoc """
  `Phoenix.LiveViewTest` coverage for `Harness.Dashboard.RoadmapLive` — the
  per-project roadmap rollup extracted from the runs dashboard onto its own
  `/harness/roadmap` page.

  `async: false` — reads the singleton `ProjectRegistry`, so a registered
  fixture project would leak across parallel tests.
  """

  # async: false because tests read singleton ProjectRegistry state.
  use Harness.Dashboard.ConnCase, async: false

  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry

  describe "mount + render" do
    test "renders the no-projects state when the registry is empty", %{conn: conn} do
      # The registry is a singleton; ensure it's empty for this assertion.
      for project <- ProjectRegistry.list(), do: ProjectRegistry.unregister(project.name)

      {:ok, _view, html} = live(conn, "/harness/roadmap")

      assert html =~ "Roadmap"
      assert html =~ "No projects registered."
    end

    test "renders a per-project rollup row for a registered project", %{conn: conn} do
      project = ProjectFixture.from_repo("/tmp/harness-roadmaplive-demo", name: "roadmaplive-demo")
      :ok = ProjectRegistry.register(project)
      on_exit(fn -> ProjectRegistry.unregister(project.name) end)

      {:ok, _view, html} = live(conn, "/harness/roadmap")

      assert html =~ "roadmaplive-demo"
      # The four rollup columns render (a /tmp path with no roadmap summarizes to
      # zeros, but the row + headers must be present).
      assert html =~ "Open"
      assert html =~ "Done"
      assert html =~ "Total"
      assert html =~ "Landed"
      assert html =~ "1 projects"
    end
  end
end
