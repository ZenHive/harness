defmodule Harness.DepFreshness.Provider.GoTest do
  use ExUnit.Case, async: true

  alias Harness.DepFreshness.Provider.Go, as: Provider
  alias Harness.DepFreshness.Row
  alias Harness.ProjectFixture

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "harness-go-freshness-#{System.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  @sample_output """
  {
    "Path": "example.test/app",
    "Main": true,
    "Dir": "/tmp/app",
    "GoMod": "/tmp/app/go.mod",
    "GoVersion": "1.22"
  }
  {
    "Path": "github.com/acme/lib",
    "Version": "v1.2.3",
    "Update": {
      "Path": "github.com/acme/lib",
      "Version": "v1.3.0"
    }
  }
  {
    "Path": "github.com/acme/major/v2",
    "Version": "v2.0.0",
    "Update": {
      "Path": "github.com/acme/major/v2",
      "Version": "v2.1.0"
    }
  }
  {
    "Path": "github.com/acme/transitive",
    "Version": "v0.4.0"
  }
  """

  test "parse_requirements/1 reads single and block require directives" do
    go_mod = """
    module example.test/app

    require github.com/acme/lib v1.2.0

    require (
      github.com/acme/major/v2 v2.0.0
      github.com/acme/transitive v0.4.0 // indirect
    )
    """

    assert Provider.parse_requirements(go_mod) == %{
             "github.com/acme/lib" => "v1.2.0",
             "github.com/acme/major/v2" => "v2.0.0",
             "github.com/acme/transitive" => "v0.4.0"
           }
  end

  test "parse_output/2 maps go list module rows mechanically" do
    requirements = %{
      "github.com/acme/lib" => "v1.2.0",
      "github.com/acme/major/v2" => "v2.0.0"
    }

    assert {:ok, rows} = Provider.parse_output(@sample_output, requirements)
    assert match?([_, _, _], rows)

    assert %Row{
             name: "github.com/acme/lib",
             current_version: "v1.2.3",
             latest_version: "v1.3.0",
             constraint_allowed: true
           } = Enum.find(rows, &(&1.name == "github.com/acme/lib"))

    assert %Row{
             name: "github.com/acme/major/v2",
             current_version: "v2.0.0",
             latest_version: "v2.1.0",
             constraint_allowed: true
           } = Enum.find(rows, &(&1.name == "github.com/acme/major/v2"))

    assert %Row{
             name: "github.com/acme/transitive",
             current_version: "v0.4.0",
             latest_version: "v0.4.0",
             constraint_allowed: true
           } = Enum.find(rows, &(&1.name == "github.com/acme/transitive"))
  end

  test "parse_output/2 marks undeclared updates as not mechanically allowed" do
    output = """
    {
      "Path": "github.com/acme/implicit",
      "Version": "v1.0.0",
      "Update": {
        "Path": "github.com/acme/implicit",
        "Version": "v1.1.0"
      }
    }
    """

    assert {:ok, [%Row{name: "github.com/acme/implicit", constraint_allowed: false}]} =
             Provider.parse_output(output, %{})
  end

  test "scan/3 runs go list readonly with injected runner", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "go.mod"), "module example.test/app\n\nrequire github.com/acme/lib v1.2.0\n")

    runner = fn "go", ["list", "-mod=readonly", "-m", "-u", "-json", "all"], ^tmp_dir ->
      {:ok, @sample_output}
    end

    project = ProjectFixture.from_repo(tmp_dir, name: "go-app", language: :go)

    assert {:ok, rows} = Provider.scan(project, tmp_dir, runner: runner)
    assert Enum.any?(rows, &(&1.name == "github.com/acme/lib"))
  end

  test "scan/3 skips visibly when go.mod is missing", %{tmp_dir: tmp_dir} do
    project = ProjectFixture.from_repo(tmp_dir, name: "missing-go-mod", language: :go)

    assert {:skipped, :missing_go_mod} =
             Provider.scan(project, tmp_dir, runner: fn _, _, _ -> flunk("runner should not run") end)
  end

  test "parse_output/2 returns parse errors for malformed payloads" do
    assert {:error, {:parse_failed, "not json"}} = Provider.parse_output("not json", %{})
  end
end
