defmodule Harness.GitFixtureTest do
  use ExUnit.Case, async: true

  alias Harness.GitFixture

  @moduletag :tmp_dir

  test "suite cleanup removes fixtures after a successful run", %{tmp_dir: tmp_dir} do
    root = populated_root(tmp_dir, "success")

    assert :ok = GitFixture.cleanup_suite_root(root, %{failures: 0})
    refute File.exists?(root)
  end

  test "suite cleanup removes fixtures after a failing run", %{tmp_dir: tmp_dir} do
    root = populated_root(tmp_dir, "failure")

    assert :ok = GitFixture.cleanup_suite_root(root, %{failures: 1})
    refute File.exists?(root)
  end

  defp populated_root(tmp_dir, name) do
    root = Path.join(tmp_dir, name)
    File.mkdir_p!(Path.join(root, "landing"))
    root
  end
end
