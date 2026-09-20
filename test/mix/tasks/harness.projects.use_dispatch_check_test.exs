defmodule Mix.Tasks.Harness.Projects.UseDispatchCheckTest do
  use ExUnit.Case, async: true

  test "legacy migration cannot bypass QA eligibility" do
    assert_raise Mix.Error, ~r/Unchecked dispatch migration is retired/, fn ->
      Mix.Tasks.Harness.Projects.UseDispatchCheck.run([])
    end
  end
end
