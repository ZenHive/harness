defmodule Harness.MixProjectTest do
  use ExUnit.Case, async: true

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
end
