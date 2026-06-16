defmodule Harness.Dashboard.ProjectExplorerTest do
  @moduledoc """
  LiveView coverage for the read-only project structure explorer.
  """

  # async: false because tests mutate ProjectRegistry and application env.
  use Harness.Dashboard.ConnCase, async: false

  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry

  setup do
    for project <- ProjectRegistry.list(), do: ProjectRegistry.unregister(project.name)

    previous_code_search = Application.get_env(:harness, :dashboard_code_search)

    on_exit(fn ->
      restore(:dashboard_code_search, previous_code_search)

      for project <- ProjectRegistry.list(), do: ProjectRegistry.unregister(project.name)
    end)

    :ok
  end

  describe "project structure explorer" do
    test "mounts for an Elixir project and lists modules with defs and defps", %{conn: conn} do
      register_project("explorer-app")
      Application.put_env(:harness, :dashboard_code_search, fake_search(definitions: demo_definitions()))

      {:ok, _view, html} = live(conn, "/harness/projects/explorer-app/explore")

      assert html =~ "Project explorer"
      assert html =~ "Demo.Search"
      assert html =~ "caller/1"
      assert html =~ "target/1"
      assert html =~ "helper/0"
      assert html =~ "defp"
    end

    test "switches registered projects from the selector", %{conn: conn} do
      register_project("alpha")
      register_project("beta")
      Application.put_env(:harness, :dashboard_code_search, fake_search(definitions: demo_definitions()))

      {:ok, view, _html} = live(conn, "/harness/projects/alpha/explore")

      html =
        view
        |> element("#project-explorer-select")
        |> render_change(%{"project" => "beta"})

      assert html =~ "beta"
    end

    test "drills into a symbol and renders caller and callee facts", %{conn: conn} do
      register_project("explorer-app")

      Application.put_env(
        :harness,
        :dashboard_code_search,
        fake_search(
          definitions: demo_definitions(),
          callers: [
            fact(:def, "Demo.Search", "caller", 1,
              caller: "Demo.Search.caller/1",
              callee: "Demo.Search.target/1",
              line: 9
            )
          ],
          callees: [
            fact(:defp, "Demo.Search", "helper", 0,
              caller: "Demo.Search.target/1",
              callee: "Demo.Search.helper/0",
              line: 14
            )
          ]
        )
      )

      {:ok, view, _html} = live(conn, "/harness/projects/explorer-app/explore")

      html =
        view
        |> element("button[phx-value-symbol='Demo.Search.target/1']")
        |> render_click()

      assert html =~ "Selected symbol"
      assert html =~ "Demo.Search.target/1"
      assert html =~ "Callers"
      assert html =~ "Demo.Search.caller/1"
      assert html =~ "Callees"
      assert html =~ "Demo.Search.helper/0"
    end

    test "renders an Elixir-only empty state for non-Elixir projects", %{conn: conn} do
      register_project("rust-app", language: :rust)
      Application.put_env(:harness, :dashboard_code_search, fake_search(definitions: []))

      {:ok, _view, html} = live(conn, "/harness/projects/rust-app/explore")

      assert html =~ "Elixir projects only"
      assert html =~ "rust"
    end

    test "renders an empty state when exograph is unavailable", %{conn: conn} do
      register_project("explorer-app")

      Application.put_env(
        :harness,
        :dashboard_code_search,
        fake_search(status: :skipped, reason: :exograph_unavailable, definitions: [])
      )

      {:ok, _view, html} = live(conn, "/harness/projects/explorer-app/explore")

      assert html =~ "Code search unavailable"
      assert html =~ "exograph"
    end
  end

  defp register_project(name, opts \\ []) do
    project = ProjectFixture.from_repo("/tmp/harness-project-explorer-#{name}", Keyword.put(opts, :name, name))
    :ok = ProjectRegistry.register(project)
    project
  end

  defp fake_search(opts) do
    definitions = Keyword.fetch!(opts, :definitions)
    callers = Keyword.get(opts, :callers, [])
    callees = Keyword.get(opts, :callees, [])
    status = Keyword.get(opts, :status, :ok)
    reason = Keyword.get(opts, :reason)

    fn
      :definitions, project, "", _opts ->
        result(project, status, reason, definitions)

      :callers, project, "Demo.Search.target/1", _opts ->
        result(project, :ok, nil, callers)

      :callees, project, "Demo.Search.target/1", _opts ->
        result(project, :ok, nil, callees)
    end
  end

  defp result(project, :ok, _reason, facts), do: {:ok, %{status: :ok, project: project, facts: facts}}

  defp result(project, :skipped, reason, facts) do
    {:ok, %{status: :skipped, project: project, reason: reason, facts: facts}}
  end

  defp demo_definitions do
    [
      fact(:defmodule, "Demo.Search", nil, nil, line: 1),
      fact(:def, "Demo.Search", "caller", 1, line: 8),
      fact(:def, "Demo.Search", "target", 1, line: 13),
      fact(:defp, "Demo.Search", "helper", 0, line: 18)
    ]
  end

  defp fact(kind, module, name, arity, opts) do
    %{
      file: Keyword.get(opts, :file, "lib/demo/search.ex"),
      line: Keyword.get(opts, :line),
      kind: kind,
      module: module,
      name: name,
      arity: arity,
      caller: Keyword.get(opts, :caller),
      callee: Keyword.get(opts, :callee)
    }
  end

  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)
end
