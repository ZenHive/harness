defmodule Harness.Lander.WorkerTest do
  use ExUnit.Case, async: true

  alias Harness.Lander.Worker

  describe "perform/1 — argument guards" do
    test "cancels when project_name is missing" do
      assert {:cancel, {:missing_arg, "project_name"}} =
               Worker.perform(%Oban.Job{args: %{"branch" => "harness/x"}})
    end

    test "cancels when branch is missing" do
      assert {:cancel, {:missing_arg, "branch"}} =
               Worker.perform(%Oban.Job{args: %{"project_name" => "demo"}})
    end
  end
end
