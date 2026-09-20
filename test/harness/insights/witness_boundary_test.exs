defmodule Harness.Insights.WitnessBoundaryTest do
  use ExUnit.Case, async: false

  alias Harness.Insights.Witness

  test "missing executable fails explicitly" do
    path = System.get_env("PATH")
    System.put_env("PATH", "")
    on_exit(fn -> System.put_env("PATH", path) end)
    assert {:error, :claude_not_installed} = Witness.observe(%{}, "sonnet")
  end

  @tag :integration
  @tag timeout: 200_000
  test "real provider rejection propagates through the witness" do
    assert {:error, {:agent_failed, status, _}} = Witness.observe(%{}, "harness-insights-invalid-model")
    assert status != 0
  end
end
