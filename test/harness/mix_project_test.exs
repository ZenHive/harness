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
end
