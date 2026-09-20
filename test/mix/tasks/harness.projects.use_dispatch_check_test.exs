defmodule Mix.Tasks.Harness.Projects.UseDispatchCheckTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Harness.Projects.UseDispatchCheck

  test "legacy migration cannot bypass QA eligibility" do
    assert_raise Mix.Error, ~r/Unchecked dispatch migration is retired/, fn ->
      UseDispatchCheck.run([])
    end
  end
end
