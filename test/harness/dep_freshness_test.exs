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
    assert snapshot.conformance.drift_count > 0
  end

  test "scan_project records JavaScript freshness rows for TypeScript projects", %{tmp_dir: tmp_dir} do
    File.write!(
      Path.join(tmp_dir, "package.json"),
      Jason.encode!(%{"devDependencies" => %{"typescript" => "^5.4.0"}})
    )

    File.write!(Path.join(tmp_dir, "package-lock.json"), "{}")

    project = ProjectFixture.from_repo(tmp_dir, name: "typescript-freshness-demo", language: :typescript)
    :ok = ProjectRegistry.register(project)

    runner = fn "npm", ["outdated", "--json"], ^tmp_dir ->
      {:ok, Jason.encode!(%{"typescript" => %{"current" => "5.4.0", "wanted" => "5.5.4", "latest" => "5.5.4"}})}
    end

    assert :ok = DepFreshness.scan_project(project, provider_opts: [runner: runner])

    assert {:ok, snapshot} = DepFreshness.fetch_snapshot("typescript-freshness-demo")
    assert snapshot.language == "typescript"
    assert snapshot.outdated_count == 1

    assert [
             %Row{
               name: "typescript",
               current_version: "5.4.0",
               latest_version: "5.5.4",
               constraint_allowed: true,
               language: :typescript
             }
           ] = snapshot.rows
  end

  test "scan_project records Go freshness rows for Go projects", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "go.mod"), "module example.test/app\n\nrequire github.com/acme/lib v1.2.0\n")
    File.write!(Path.join(tmp_dir, "go.sum"), "github.com/acme/lib v1.2.0 h1:fixture\n")

    project = ProjectFixture.from_repo(tmp_dir, name: "go-freshness-demo", language: :go)
    :ok = ProjectRegistry.register(project)

    output = """
    {
      "Path": "example.test/app",
      "Main": true
    }
    {
      "Path": "github.com/acme/lib",
      "Version": "v1.2.3",
      "Update": {
        "Path": "github.com/acme/lib",
        "Version": "v1.3.0"
      }
    }
    """

    runner = fn "go", ["list", "-mod=readonly", "-m", "-u", "-json", "all"], ^tmp_dir -> {:ok, output} end

    assert :ok = DepFreshness.scan_project(project, provider_opts: [runner: runner])

    assert {:ok, snapshot} = DepFreshness.fetch_snapshot("go-freshness-demo")
    assert snapshot.language == "go"
    assert snapshot.outdated_count == 1

    assert [
             %Row{
               name: "github.com/acme/lib",
               current_version: "v1.2.3",
               latest_version: "v1.3.0",
               constraint_allowed: true,
               language: :go
             }
           ] = snapshot.rows
  end

  test "scan_project records skipped Go facts when module metadata is missing", %{tmp_dir: tmp_dir} do
    project = ProjectFixture.from_repo(tmp_dir, name: "missing-go-module", language: :go)
    :ok = ProjectRegistry.register(project)

    assert :ok =
             DepFreshness.scan_project(project, provider_opts: [runner: fn _, _, _ -> flunk("runner should not run") end])

    assert {:ok, snapshot} = DepFreshness.fetch_snapshot("missing-go-module")

    assert [
             %Row{
               name: "provider:go",
               status: :skipped,
               reason: :missing_go_mod,
               language: :go
             }
           ] = snapshot.rows
  end

  test "scan_project records skipped JavaScript facts when manager metadata is missing", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "package.json"), Jason.encode!(%{"dependencies" => %{"react" => "^18.2.0"}}))

    project = ProjectFixture.from_repo(tmp_dir, name: "missing-js-manager", language: :javascript)
    :ok = ProjectRegistry.register(project)

    assert :ok =
             DepFreshness.scan_project(project, provider_opts: [runner: fn _, _, _ -> flunk("runner should not run") end])

    assert {:ok, snapshot} = DepFreshness.fetch_snapshot("missing-js-manager")

    assert [
             %Row{
               name: "provider:javascript",
               status: :skipped,
               reason: :missing_package_manager_metadata,
               language: :javascript
             }
           ] = snapshot.rows
  end

  test "scan_project records tooling baseline facts for explicit Elixir projects", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "mix.exs"), "Mix.install([])")
    File.mkdir!(Path.join(tmp_dir, "deps"))

    project = ProjectFixture.from_repo(tmp_dir, name: "baseline-demo", language: :elixir)
    :ok = ProjectRegistry.register(project)

    output = """
    Dependency         Only      Current  Latest   Status
    """

    runner = fn "mix", ["hex.outdated"], ^tmp_dir -> {:ok, output} end

    assert :ok = DepFreshness.scan_project(project, provider_opts: [runner: runner])

    assert {:ok, snapshot} = DepFreshness.fetch_snapshot("baseline-demo")
    assert snapshot.conformance.drift_count > 0
    assert Enum.any?(snapshot.conformance.items, &(&1.status == :missing))
  end

  test "scan_project records tooling baseline facts when freshness scan fails", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "mix.exs"), "Mix.install([])")
    File.mkdir!(Path.join(tmp_dir, "deps"))

    project = ProjectFixture.from_repo(tmp_dir, name: "baseline-despite-freshness-error", language: :elixir)
    :ok = ProjectRegistry.register(project)

    runner = fn "mix", ["hex.outdated"], ^tmp_dir -> {:error, :hex_failed} end

    assert {:error, {:provider_errors, [elixir: :hex_failed]}} =
             DepFreshness.scan_project(project, provider_opts: [runner: runner])

    assert {:ok, snapshot} = DepFreshness.fetch_snapshot("baseline-despite-freshness-error")
    assert [%Row{name: "provider:elixir", status: :skipped, reason: :hex_failed}] = snapshot.rows
    assert snapshot.conformance.drift_count > 0
    assert Enum.any?(snapshot.conformance.items, &(&1.id == "dep:credo" and &1.status == :missing))
  end

  test "scan_project records Rust freshness rows for Rust projects", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "Cargo.toml"), cargo_toml())

    project = ProjectFixture.from_repo(tmp_dir, name: "rust-freshness-demo", language: :rust)
    :ok = ProjectRegistry.register(project)

    output =
      Jason.encode!(%{
        "crate_name" => "rust_freshness_demo",
        "dependencies" => [
          %{"name" => "serde", "project" => "1.0.0", "compat" => "---", "latest" => "1.0.228"}
        ]
      })

    runner = fn
      "cargo", ["outdated", "--version"], ^tmp_dir -> {:ok, "cargo-outdated-outdated 0.19.0"}
      "cargo", ["outdated", "--format", "json", "-R"], ^tmp_dir -> {:ok, output}
    end

    assert :ok = DepFreshness.scan_project(project, provider_opts: [runner: runner])

    assert {:ok, snapshot} = DepFreshness.fetch_snapshot("rust-freshness-demo")
    assert snapshot.language == "rust"
    assert snapshot.outdated_count == 1

    assert [
             %Row{
               name: "serde",
               current_version: "1.0.0",
               latest_version: "1.0.228",
               constraint_allowed: false,
               language: :rust
             }
           ] = snapshot.rows
  end

  test "scan_project records skipped facts for unsupported languages" do
    project = ProjectFixture.from_repo("/tmp/harness-python-freshness", name: "python-demo", language: :python)

    assert :ok = DepFreshness.scan_project(project)
    assert {:ok, snapshot} = DepFreshness.fetch_snapshot("python-demo")
    assert snapshot.language == "python"
    assert snapshot.outdated_count == 0
    assert [%Row{name: "provider:python", status: :skipped, language: :python}] = snapshot.rows
  end

  test "scan_project records skipped Rust facts when Cargo metadata is missing", %{tmp_dir: tmp_dir} do
    project = ProjectFixture.from_repo(tmp_dir, name: "rust-missing-cargo", language: :rust)
    :ok = ProjectRegistry.register(project)

    assert :ok =
             DepFreshness.scan_project(project, provider_opts: [runner: fn _, _, _ -> flunk("runner should not run") end])

    assert {:ok, snapshot} = DepFreshness.fetch_snapshot("rust-missing-cargo")
    assert snapshot.language == "rust"
    assert snapshot.outdated_count == 0
    assert [%Row{name: "provider:rust", status: :skipped, reason: :missing_cargo_toml, language: :rust}] = snapshot.rows
  end

  test "scan_project records Elixir and Rust rows for mixed projects", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "mix.exs"), "Mix.install([])")
    File.mkdir!(Path.join(tmp_dir, "deps"))
    File.write!(Path.join(tmp_dir, "Cargo.toml"), cargo_toml())

    project = ProjectFixture.from_repo(tmp_dir, name: "mixed-demo", languages: [:elixir, :rust])
    :ok = ProjectRegistry.register(project)

    output = """
    Dependency         Only      Current  Latest   Status
    req                          0.6.1    0.6.2    Update possible
    """

    rust_output =
      Jason.encode!(%{
        "crate_name" => "mixed_demo",
        "dependencies" => [
          %{"name" => "serde", "project" => "1.0.0", "compat" => "1.0.228", "latest" => "1.0.228"}
        ]
      })

    runner = fn
      "mix", ["hex.outdated"], ^tmp_dir -> {:ok, output}
      "cargo", ["outdated", "--version"], ^tmp_dir -> {:ok, "cargo-outdated-outdated 0.19.0"}
      "cargo", ["outdated", "--format", "json", "-R"], ^tmp_dir -> {:ok, rust_output}
    end

    assert :ok = DepFreshness.scan_project(project, provider_opts: [runner: runner])

    assert {:ok, snapshot} = DepFreshness.fetch_snapshot("mixed-demo")
    assert snapshot.language == "elixir,rust"
    assert snapshot.outdated_count == 2
    assert Enum.any?(snapshot.rows, &match?(%Row{name: "req", language: :elixir}, &1))
    assert Enum.any?(snapshot.rows, &match?(%Row{name: "serde", language: :rust}, &1))
    assert snapshot.conformance.drift_count > 0
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
      roadmap_path: "/tmp/github-demo",
      languages: [:elixir]
    }

    assert {:skipped, :github_source} = DepFreshness.scan_project(project)
  end

  @spec cargo_toml() :: String.t()
  defp cargo_toml do
    """
    [package]
    name = "rust_freshness_demo"
    version = "0.1.0"
    edition = "2021"

    [dependencies]
    serde = "=1.0.0"
    """
  end
end
