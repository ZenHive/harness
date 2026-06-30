defmodule Harness.ToolingBaseline.MixProjectReaderTest do
  use ExUnit.Case, async: true

  alias Harness.ToolingBaseline.MixProjectReader

  test "reads deps and aliases from a Mix.Project module" do
    mix_exs = """
    defmodule Demo.MixProject do
      use Mix.Project

      defp deps do
        [
          {:credo, "~> 1.7", only: [:dev, :test]},
          {:req, "~> 0.5"}
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

    path = write_mix!(mix_exs)

    assert {:ok, %{deps: deps, aliases: aliases}} = MixProjectReader.read(path)
    assert MapSet.member?(deps, :credo)
    assert MapSet.member?(deps, :req)
    assert MapSet.member?(aliases, :precommit)
    assert MapSet.member?(aliases, :ci)
  end

  test "reads deps from Mix.install scripts" do
    mix_exs = """
    Mix.install([
      {:credo, "~> 1.7"},
      :req
    ])
    """

    path = write_mix!(mix_exs)

    assert {:ok, %{deps: deps}} = MixProjectReader.read(path)
    assert MapSet.member?(deps, :credo)
    assert MapSet.member?(deps, :req)
  end

  @spec write_mix!(String.t()) :: String.t()
  defp write_mix!(content) do
    dir = Path.join(System.tmp_dir!(), "harness-mix-reader-#{System.unique_integer()}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "mix.exs")
    File.write!(path, content)
    path
  end
end
