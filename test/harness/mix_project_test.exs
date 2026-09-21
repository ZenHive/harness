defmodule Harness.MixProjectTest do
  use ExUnit.Case, async: true

  @heavy_dispatch_steps ~w(dialyzer reach.check ex_dna --cover credo doctor sobelow test)

  test "bounded subprocess support is included in the runtime application dependencies" do
    assert :muontrap in Application.spec(:harness, :applications)
    assert Code.ensure_loaded?(MuonTrap)
    assert function_exported?(MuonTrap, :cmd, 3)
  end

  test "precommit enforces sobelow exit status while honoring skips" do
    aliases = Keyword.fetch!(Harness.MixProject.project(), :aliases)

    assert "sobelow --exit --skip" in Keyword.fetch!(aliases, :precommit)
  end

  test "sobelow baseline alias marks all displayed findings as skippable" do
    aliases = Keyword.fetch!(Harness.MixProject.project(), :aliases)

    assert Keyword.fetch!(aliases, :"sobelow.baseline") == ["sobelow --mark-skip-all"]
  end

  test "precommit full checks dependency constraints" do
    aliases = Keyword.fetch!(Harness.MixProject.project(), :aliases)

    assert "harness.deps.check" in Keyword.fetch!(aliases, :"precommit.full")
  end

  test "check.dispatch exists as a cheap per-dispatch gate" do
    aliases = Harness.MixProject.project() |> Keyword.fetch!(:aliases) |> Map.new()

    assert [
             "format --check-formatted",
             "compile --warnings-as-errors"
           ] = Map.fetch!(aliases, :"check.dispatch")

    for analyzer <- ["credo --strict --ignore TagTODO,TagFIXME", "doctor --raise", "sobelow --exit --skip"] do
      assert analyzer in Map.fetch!(aliases, :precommit)
    end

    dispatch_steps = Enum.join(Map.fetch!(aliases, :"check.dispatch"), "\n")

    for heavy_step <- @heavy_dispatch_steps do
      refute dispatch_steps =~ heavy_step
    end
  end
end
