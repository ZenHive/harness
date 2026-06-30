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

  test "reads repo-local files" do
    path = Path.join(File.cwd!(), "dependency_constraint_guard_#{System.unique_integer([:positive])}.mix.exs")
    File.write!(path, ~s({:plug, "~> 1.19.2"}))

    on_exit(fn -> File.rm(path) end)

    assert {:ok, [%{line: 1, constraint: "~> 1.19.2"}]} =
             DependencyConstraintGuard.violations(path)
  end

  test "rejects paths outside the repo root" do
    path = Path.join(System.tmp_dir!(), "dependency_constraint_guard.mix.exs")

    assert {:error, :eacces} = DependencyConstraintGuard.violations(path)
  end
end
