defmodule Harness.DepFreshnessTest do
  use ExUnit.Case, async: false

  alias Harness.DepFreshness
  alias Harness.DepFreshness.Row
  alias Harness.DepFreshnessStore.Memory, as: Store
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry

  setup do
    prev = Application.get_env(:harness, :dep_freshness_store)
    Application.put_env(:harness, :dep_freshness_store, {Store, scope: :dep_freshness_test})

    for project <- ProjectRegistry.list(), do: ProjectRegistry.unregister(project.name)

    tmp_dir = Path.join(System.tmp_dir!(), "harness-freshness-#{System.unique_integer()}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      Application.put_env(:harness, :dep_freshness_store, prev)
      File.rm_rf!(tmp_dir)

      for project <- ProjectRegistry.list(), do: ProjectRegistry.unregister(project.name)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "scan_project records provider rows for an Elixir project", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "mix.exs"), "Mix.install([])")
    File.mkdir!(Path.join(tmp_dir, "deps"))

    project = ProjectFixture.from_repo(tmp_dir, name: "freshness-demo")
    :ok = ProjectRegistry.register(project)

    output = """
    Dependency         Only      Current  Latest   Status
    req                          0.6.1    0.6.2    Update possible
    """

    runner = fn "mix", ["hex.outdated"], ^tmp_dir -> {:ok, output} end

    assert :ok = DepFreshness.scan_project(project, provider_opts: [runner: runner])

    assert {:ok, snapshot} = DepFreshness.fetch_snapshot("freshness-demo")
    assert snapshot.outdated_count == 1
    assert [%Row{name: "req"}] = snapshot.rows
  end

  test "scan_project skips unsupported languages" do
    project = ProjectFixture.from_repo("/tmp/harness-rust-freshness", name: "rust-demo", language: :rust)
    :ok = ProjectRegistry.register(project)

    assert {:skipped, {:unsupported_language, :rust}} = DepFreshness.scan_project(project)
    assert {:error, :not_found} = DepFreshness.fetch_snapshot("rust-demo")
  end

  test "scan_all records all registered Elixir projects", %{tmp_dir: tmp_dir} do
    one = Path.join(tmp_dir, "one")
    two = Path.join(tmp_dir, "two")
    File.mkdir_p!(Path.join(one, "deps"))
    File.mkdir_p!(Path.join(two, "deps"))
    File.write!(Path.join(one, "mix.exs"), "Mix.install([])")
    File.write!(Path.join(two, "mix.exs"), "Mix.install([])")

    :ok = ProjectRegistry.register(ProjectFixture.from_repo(one, name: "freshness-one", language: :elixir))
    :ok = ProjectRegistry.register(ProjectFixture.from_repo(two, name: "freshness-two", language: :elixir))

    output = """
    Dependency         Only      Current  Latest   Status
    req                          0.6.1    0.6.2    Update possible
    """

    runner = fn "mix", ["hex.outdated"], path when path in [one, two] -> {:ok, output} end

    assert :ok = DepFreshness.scan_all(provider_opts: [runner: runner])
    assert {:ok, [snapshot]} = DepFreshness.list_snapshots(project_name: "freshness-two")
    assert snapshot.language == "elixir"
  end

  test "scan_project skips github sources" do
    project = %Harness.Project{
      name: "github-demo",
      source: {:github, "https://github.com/example/demo.git"},
      roadmap_path: "/tmp/github-demo"
    }

    assert {:skipped, :github_source} = DepFreshness.scan_project(project)
  end
end
