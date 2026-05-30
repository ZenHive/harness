defmodule Harness.Dashboard.ConnCase do
  @moduledoc """
  Test case for `Phoenix.LiveViewTest`-driven dashboard tests.

  Wires the standalone `Harness.Dashboard.Endpoint` (started in
  `test/test_helper.exs`, `server: false`) so `live/2` can mount the dashboard
  LiveViews and drive their events without a real HTTP server.

  Async-safety is the consuming module's call, not a blanket guarantee: a test
  that registers a fixture project or starts an in-flight run touches the global
  `ProjectRegistry` / run registry / `StatusView` snapshot, so it must declare
  `async: false` (both current consumers do). A test that only mounts and reads
  immutable render output can run `async: true`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import Plug.Conn

      @endpoint Harness.Dashboard.Endpoint
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
