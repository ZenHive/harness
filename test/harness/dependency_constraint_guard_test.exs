defmodule Harness.DependencyConstraintGuardTest do
  use ExUnit.Case, async: true

  alias Harness.DependencyConstraintGuard

  test "flags an over-tight three-part optimistic dep constraint" do
    content = ~s({:plug, "~> 1.19.2"})

    assert [%{line: 1, constraint: "~> 1.19.2"}] =
             DependencyConstraintGuard.violations_in(content)
  end

  test "accepts a justified three-part optimistic dep constraint" do
    content = ~s({:plug, "~> 1.19.2"} # tight pin: 1.20 changed parser behavior)

    assert [] = DependencyConstraintGuard.violations_in(content)
  end
end
