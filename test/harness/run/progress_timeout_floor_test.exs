defmodule Harness.Run.ProgressTimeoutFloorTest do
  use Harness.RunCase, async: true

  alias Harness.Run.Actions.Recovery
  alias Harness.Run.Actions.Reviewing
  alias Harness.Run.Actions.Worktree, as: WorktreeActions

  describe "reviewer progress-timeout floor" do
    test "nil progress (Driver default) is raised to the 15-min floor" do
      # Without this the reviewer keeps the adapter's 300_000 default, and a
      # silent `mix ci` reads as a stalled agent to the progress watchdog.
      assert Run.reviewer_progress_timeout(nil) == 900_000
    end

    test "a progress override below the floor is raised to the floor" do
      assert Run.reviewer_progress_timeout(150) == 900_000
    end

    test "a progress override above the floor wins" do
      assert Run.reviewer_progress_timeout(1_800_000) == 1_800_000
    end

    test "an explicit :infinity progress is preserved" do
      assert Run.reviewer_progress_timeout(:infinity) == :infinity
    end
  end

  describe "implementer progress-timeout floor" do
    test "nil progress is raised to the 15-min floor" do
      assert Run.implementer_progress_timeout(nil) == 900_000
    end

    test "a progress override below the floor is raised to the floor" do
      assert Run.implementer_progress_timeout(1_000) == 900_000
    end

    test "a progress override above the floor wins" do
      assert Run.implementer_progress_timeout(1_800_000) == 1_800_000
    end

    test "an explicit :infinity progress is preserved" do
      assert Run.implementer_progress_timeout(:infinity) == :infinity
    end
  end

  describe "the floor reaches the driver opts of every phase" do
    test "the reviewer's driver opts carry the floored progress window" do
      opts = Reviewing.reviewer_driver_opts(timeout_data(nil), self())

      assert Keyword.fetch!(opts, :progress_timeout) == 900_000
      assert Keyword.fetch!(opts, :idle_timeout) == 600_000
    end

    test "the implementer's driver opts carry the floored progress window" do
      opts = WorktreeActions.driver_opts(timeout_data(nil), self())

      assert Keyword.fetch!(opts, :progress_timeout) == 900_000
    end

    test "the recovery phase's driver opts carry the floored progress window" do
      opts = Recovery.recovery_driver_opts(timeout_data(nil), self())

      assert Keyword.fetch!(opts, :progress_timeout) == 900_000
    end

    test "an explicit higher progress window survives into the driver opts" do
      opts = Reviewing.reviewer_driver_opts(timeout_data(1_800_000), self())

      assert Keyword.fetch!(opts, :progress_timeout) == 1_800_000
    end
  end

  defp timeout_data(progress) do
    %{total_timeout: 1_800_000, idle_timeout: nil, progress_timeout: progress}
  end
end
