defmodule Harness.Dashboard.SuiteHealthLiveTest do
  use Harness.Dashboard.ConnCase, async: false

  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.SuiteHealth.Result
  alias Harness.SuiteHealthStore
  alias Harness.SuiteHealthStore.Memory, as: Store

  setup %{conn: conn} do
    prev = Application.get_env(:harness, :suite_health_store)
    Application.put_env(:harness, :suite_health_store, {Store, scope: :suite_health_live_test})

    for project <- ProjectRegistry.list(), do: ProjectRegistry.unregister(project.name)

    project = ProjectFixture.from_repo("/tmp/harness-suite-health-live", name: "health-live")
    :ok = ProjectRegistry.register(project)

    on_exit(fn ->
      Application.put_env(:harness, :suite_health_store, prev)
      ProjectRegistry.unregister("health-live")
    end)

    {:ok, conn: conn, project: project}
  end

  test "renders failing tests raw", %{conn: conn} do
    result =
      Result.build("health-live",
        passed: false,
        exit_code: 2,
        command: "mix test.json --include integration",
        failing_tests: [%{name: "demo red", file: "test/demo_test.exs", line: 4}],
        languages: "elixir"
      )

    assert :ok = SuiteHealthStore.record_result(result, SuiteHealthStore.configured())

    {:ok, _view, html} = live(conn, "/harness/health/health-live")

    assert html =~ "Suite health"
    assert html =~ "Failed"
    assert html =~ "demo red"
    assert html =~ "test/demo_test.exs"
  end
end
