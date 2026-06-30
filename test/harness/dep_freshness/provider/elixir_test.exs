defmodule Harness.DepFreshness.Provider.ElixirTest do
  use ExUnit.Case, async: true

  alias Harness.DepFreshness.Provider.Elixir, as: Provider
  alias Harness.DepFreshness.Row
  alias Harness.ProjectFixture

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "harness-freshness-#{System.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  @sample_output """
  Dependency         Only      Current  Latest   Status
  anubis_mcp                   1.6.2    1.6.2    Up-to-date
  dune               dev,test  0.3.16   0.3.17   Update possible
  ex_unit_json       dev,test  0.5.0    0.6.0    Update not possible

  Run `mix hex.outdated APP` to see requirements for a specific dependency.
  """

  test "parse_output/1 maps hex.outdated rows mechanically" do
    assert {:ok, rows} = Provider.parse_output(@sample_output)
    assert length(rows) == 3

    assert %Row{
             name: "dune",
             current_version: "0.3.16",
             latest_version: "0.3.17",
             constraint_allowed: true
           } = Enum.find(rows, &(&1.name == "dune"))

    assert %Row{
             name: "ex_unit_json",
             current_version: "0.5.0",
             latest_version: "0.6.0",
             constraint_allowed: false
           } = Enum.find(rows, &(&1.name == "ex_unit_json"))
  end

  test "scan/3 uses injected runner and skips deps.get when deps/ exists", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "mix.exs"), "Mix.install([])")
    File.mkdir!(Path.join(tmp_dir, "deps"))

    runner = fn "mix", ["hex.outdated"], ^tmp_dir ->
      {:ok, @sample_output}
    end

    project = ProjectFixture.from_repo(tmp_dir, name: "deps-app")

    assert {:ok, rows} = Provider.scan(project, tmp_dir, runner: runner)
    assert Enum.any?(rows, &(&1.name == "dune"))
  end

  test "scan/3 runs deps.get when deps/ is missing", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "mix.exs"), "Mix.install([])")

    calls = :atomics.new(1, [])

    runner = fn
      "mix", ["deps.get", "--quiet"], ^tmp_dir ->
        :atomics.add(calls, 1, 1)
        File.mkdir!(Path.join(tmp_dir, "deps"))
        {:ok, ""}

      "mix", ["hex.outdated"], ^tmp_dir ->
        {:ok, @sample_output}
    end

    project = ProjectFixture.from_repo(tmp_dir, name: "cold-app")
    assert {:ok, _rows} = Provider.scan(project, tmp_dir, runner: runner)
    assert :atomics.get(calls, 1) == 1
  end

  test "scan/3 returns deps.get errors", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "mix.exs"), "Mix.install([])")

    runner = fn "mix", ["deps.get", "--quiet"], ^tmp_dir -> {:error, :offline} end

    project = ProjectFixture.from_repo(tmp_dir, name: "cold-error-app")
    assert {:error, :offline} = Provider.scan(project, tmp_dir, runner: runner)
  end

  test "parse_output/1 ignores malformed table rows" do
    output = """
    Dependency         Only      Current  Latest   Status
    malformed
    req                          0.6.1    0.6.2    Update possible
    """

    assert {:ok, [%Row{name: "req"}]} = Provider.parse_output(output)
  end

  test "parse_output/1 fails when hex.outdated returns no table" do
    assert {:error, {:parse_failed, "boom"}} = Provider.parse_output("boom")
  end

  test "scan/3 returns parse errors instead of recording empty rows", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "mix.exs"), "Mix.install([])")
    File.mkdir!(Path.join(tmp_dir, "deps"))

    runner = fn "mix", ["hex.outdated"], ^tmp_dir -> {:ok, "boom"} end

    project = ProjectFixture.from_repo(tmp_dir, name: "parse-error-app")
    assert {:error, {:parse_failed, "boom"}} = Provider.scan(project, tmp_dir, runner: runner)
  end

  test "scan/3 uses the default mix runner", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "mix.exs"), mix_project())
    File.mkdir!(Path.join(tmp_dir, "deps"))

    project = ProjectFixture.from_repo(tmp_dir, name: "default-runner-app")

    assert {:error, {:parse_failed, output}} = Provider.scan(project, tmp_dir, [])
    assert output =~ "No hex dependencies"
  end

  test "scan/3 skips when mix.exs is missing", %{tmp_dir: tmp_dir} do
    project = ProjectFixture.from_repo(tmp_dir, name: "no-mix")
    assert {:skipped, :missing_mix_exs} = Provider.scan(project, tmp_dir, runner: fn _, _, _ -> flunk("runner") end)
  end

  @spec mix_project() :: String.t()
  defp mix_project do
    """
    defmodule FreshnessDemo.MixProject do
      use Mix.Project

      def project, do: [app: :freshness_demo, version: "0.1.0", deps: []]
      def application, do: []
    end
    """
  end
end
