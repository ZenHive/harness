defmodule Harness.ToolingBaseline.Provider.ElixirTest do
  use ExUnit.Case, async: true

  alias Harness.ProjectFixture
  alias Harness.ToolingBaseline.Item
  alias Harness.ToolingBaseline.Provider.Elixir, as: Provider

  test "records missing baseline items as drift" do
    dir = baseline_dir!()
    project = ProjectFixture.from_repo(dir, name: "baseline-missing", language: :elixir)

    assert {:ok, snapshot} = Provider.scan(project, dir, [])

    assert snapshot.drift_count > 0
    assert Enum.any?(snapshot.items, &(&1.id == "dep:credo" and &1.status == :missing))
    assert Enum.any?(snapshot.items, &(&1.id == "alias:precommit" and &1.status == :missing))
    assert Enum.any?(snapshot.items, &(&1.id == "config:.credo.exs" and &1.status == :missing))
    assert length(snapshot.advisory) == 3
  end

  test "records overrides as facts instead of silent skips" do
    dir = baseline_dir!()

    project =
      ProjectFixture.from_repo(dir,
        name: "baseline-override",
        language: :elixir,
        tooling_baseline_overrides: %{"dep:credo" => "legacy stack"}
      )

    assert {:ok, snapshot} = Provider.scan(project, dir, [])

    assert %Item{id: "dep:credo", status: :overridden, override_reason: "legacy stack"} =
             Enum.find(snapshot.items, &(&1.id == "dep:credo"))

    refute Item.drift?(Enum.find(snapshot.items, &(&1.id == "dep:credo")))
  end

  test "marks present committed surface items" do
    dir = baseline_dir!()

    mix_exs = """
    defmodule Present.MixProject do
      use Mix.Project

      defp deps do
        [
          {:credo, "~> 1.7", only: [:dev, :test]},
          {:ex_slop, "~> 0.4", only: [:dev, :test]},
          {:dialyxir, "~> 1.4", only: [:dev, :test]},
          {:ex_dna, "~> 1.5", only: [:dev, :test]},
          {:reach, "~> 2.7", only: [:dev, :test]},
          {:sobelow, "~> 0.14", only: [:dev, :test]},
          {:doctor, "~> 0.23", only: [:dev, :test]},
          {:ex_unit_json, "~> 0.6", only: [:dev, :test]},
          {:dialyzer_json, "~> 0.2", only: [:dev, :test]},
          {:styler, "~> 1.11", only: [:dev, :test]}
        ]
      end

      defp aliases do
        [
          precommit: ["format --check-formatted"],
          ci: ["precommit.full"]
        ]
      end
    end
    """

    File.write!(Path.join(dir, "mix.exs"), mix_exs)
    File.write!(Path.join(dir, ".credo.exs"), "%{}")
    File.write!(Path.join(dir, ".reach.exs"), "%{}")
    File.write!(Path.join(dir, ".formatter.exs"), "[]")

    project = ProjectFixture.from_repo(dir, name: "baseline-present", language: :elixir)

    assert {:ok, snapshot} = Provider.scan(project, dir, [])
    assert snapshot.drift_count == 0
    assert Enum.all?(snapshot.items, &(&1.status == :present))
  end

  test "skips projects without mix.exs" do
    dir = Path.join(System.tmp_dir!(), "harness-baseline-skip-#{System.unique_integer()}")
    File.mkdir_p!(dir)
    project = ProjectFixture.from_repo(dir, name: "baseline-skip", language: :elixir)

    assert {:skipped, :missing_mix_exs} = Provider.scan(project, dir, [])
  end

  @spec baseline_dir!() :: String.t()
  defp baseline_dir! do
    dir = Path.join(System.tmp_dir!(), "harness-baseline-#{System.unique_integer()}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "mix.exs"), "Mix.install([])")
    dir
  end
end
