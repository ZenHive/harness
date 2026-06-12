defmodule Harness.Run.ReviewerIdleTimeoutTest do
  use Harness.RunCase, async: true

  describe "reviewer idle-timeout floor (Task 181)" do
    test "nil idle (Driver default) is raised to the 10-min reviewing floor" do
      # No caller override would otherwise leave the reviewer on the Driver's
      # 5-min idle default — too tight for a silent cold check run.
      assert Run.reviewer_idle_timeout(nil) == 600_000
    end

    test "an idle override below the floor is raised to the floor" do
      assert Run.reviewer_idle_timeout(150) == 600_000
    end

    test "an idle override above the floor wins" do
      assert Run.reviewer_idle_timeout(900_000) == 900_000
    end

    test "an explicit :infinity idle is preserved" do
      assert Run.reviewer_idle_timeout(:infinity) == :infinity
    end
  end
end
