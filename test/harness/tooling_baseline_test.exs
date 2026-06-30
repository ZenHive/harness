defmodule Harness.ToolingBaselineTest do
  use ExUnit.Case, async: true

  alias Harness.ProjectFixture
  alias Harness.ToolingBaseline
  alias Harness.ToolingBaseline.Item

  test "records skipped baseline facts for unsupported languages" do
    dir = baseline_dir!()
    project = ProjectFixture.from_repo(dir, name: "baseline-rust", languages: [:rust])

    assert {:ok, snapshot} = ToolingBaseline.scan_project(project, dir)
    assert snapshot.drift_count == 0
    assert [%Item{id: "provider:rust", category: :provider, status: :skipped}] = snapshot.items
  end

  test "records Elixir baseline facts and unsupported facts for mixed projects" do
    dir = baseline_dir!()
    project = ProjectFixture.from_repo(dir, name: "baseline-mixed", languages: [:elixir, :rust])

    assert {:ok, snapshot} = ToolingBaseline.scan_project(project, dir)
    assert snapshot.drift_count > 0
    assert Enum.any?(snapshot.items, &(&1.id == "dep:credo" and &1.status == :missing))
    assert Enum.any?(snapshot.items, &(&1.id == "provider:rust" and &1.status == :skipped))
  end

  @spec baseline_dir!() :: String.t()
  defp baseline_dir! do
    dir = Path.join(System.tmp_dir!(), "harness-tooling-baseline-#{System.unique_integer()}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "mix.exs"), "Mix.install([])")
    dir
  end
end
