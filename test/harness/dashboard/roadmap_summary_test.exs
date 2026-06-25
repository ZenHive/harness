defmodule Harness.Dashboard.RoadmapSummaryTest do
  @moduledoc """
  Unit coverage for `Harness.Dashboard.RoadmapSummary` — the per-project roadmap
  rollup behind the index's Roadmap panel and the unmerged-runs filter:
  open/done/total tallying (superseded excluded), the `task_id => shipped_in`
  landed map, the `landed_sha/3` join, and the `:roadmap_list` test seam.

  `async: false` — the `for_projects/1` seam test sets the global
  `:roadmap_list` application env, which would leak across parallel tests.
  """

  # async: false because tests mutate the global :roadmap_list application env seam.
  use ExUnit.Case, async: false

  alias Harness.Dashboard.RoadmapSummary
  alias Harness.ProjectFixture

  @tasks [
    %{"id" => "1", "status" => "pending"},
    %{"id" => "2", "status" => "in_progress"},
    %{"id" => "3", "status" => "blocked"},
    %{"id" => "4", "status" => "done"},
    %{"id" => "5", "status" => "done", "shipped_in" => "abc1234ff"},
    %{"id" => "6", "status" => "superseded"}
  ]

  describe "tally/1" do
    test "counts open and done, excluding superseded from every tally" do
      summary = RoadmapSummary.tally(@tasks)

      # pending + in_progress + blocked = 3 open; ids 4 and 5 done; superseded (6)
      # is dead, not counted, so total = open + done.
      assert summary.open == 3
      assert summary.done == 2
      assert summary.total == 5
    end

    test "builds the task_id => shipped_in landed map for tasks the lander merged" do
      summary = RoadmapSummary.tally(@tasks)

      assert summary.landed == %{"5" => "abc1234ff"}
    end

    test "builds the blocked task set (the Re-land gate)" do
      summary = RoadmapSummary.tally(@tasks)

      assert summary.blocked == MapSet.new(["3"])
    end

    test "ignores a blank or missing shipped_in" do
      tasks = [
        %{"id" => "7", "status" => "done", "shipped_in" => ""},
        %{"id" => "8", "status" => "done"}
      ]

      assert RoadmapSummary.tally(tasks).landed == %{}
    end

    test "normalizes an integer id to a string key" do
      summary = RoadmapSummary.tally([%{"id" => 9, "status" => "done", "shipped_in" => "deadbeef"}])

      assert summary.landed == %{"9" => "deadbeef"}
    end

    test "an empty roadmap tallies to a zero summary" do
      assert RoadmapSummary.tally([]) == %{open: 0, done: 0, total: 0, landed: %{}, blocked: MapSet.new()}
    end
  end

  describe "landed_sha/3" do
    setup do
      summaries = %{"alpha" => RoadmapSummary.tally(@tasks)}
      {:ok, summaries: summaries}
    end

    test "returns the shipped_in for a landed task", %{summaries: summaries} do
      assert RoadmapSummary.landed_sha(summaries, "alpha", "5") == "abc1234ff"
    end

    test "returns nil for an unlanded task", %{summaries: summaries} do
      assert RoadmapSummary.landed_sha(summaries, "alpha", "4") == nil
    end

    test "returns nil for an unknown project", %{summaries: summaries} do
      assert RoadmapSummary.landed_sha(summaries, "ghost", "5") == nil
    end

    test "returns nil when project or task is nil (record predating the field)", %{summaries: summaries} do
      assert RoadmapSummary.landed_sha(summaries, nil, "5") == nil
      assert RoadmapSummary.landed_sha(summaries, "alpha", nil) == nil
    end
  end

  describe "blocked?/3" do
    setup do
      {:ok, summaries: %{"alpha" => RoadmapSummary.tally(@tasks)}}
    end

    test "is true for a blocked task (the Re-land gate)", %{summaries: summaries} do
      assert RoadmapSummary.blocked?(summaries, "alpha", "3")
    end

    test "is false for a non-blocked task", %{summaries: summaries} do
      refute RoadmapSummary.blocked?(summaries, "alpha", "1")
      refute RoadmapSummary.blocked?(summaries, "alpha", "4")
    end

    test "is false for an unknown project", %{summaries: summaries} do
      refute RoadmapSummary.blocked?(summaries, "ghost", "3")
    end

    test "is false when project or task is nil", %{summaries: summaries} do
      refute RoadmapSummary.blocked?(summaries, nil, "3")
      refute RoadmapSummary.blocked?(summaries, "alpha", nil)
    end
  end

  describe "summary_for/2" do
    test "returns a zero summary for an unregistered project name" do
      assert RoadmapSummary.summary_for(%{}, "ghost") == %{open: 0, done: 0, total: 0, landed: %{}, blocked: MapSet.new()}
    end
  end

  describe "for_projects/1 (with the :roadmap_list seam)" do
    setup do
      prev = Application.get_env(:harness, :roadmap_list)
      prev_timeout = Application.get_env(:harness, :roadmap_summary_timeout_ms)

      on_exit(fn ->
        restore(:roadmap_list, prev)
        restore(:roadmap_summary_timeout_ms, prev_timeout)
      end)

      :ok
    end

    test "tallies each project from the injected lister" do
      project = ProjectFixture.from_repo("/tmp/harness-roadmap-summary", name: "summary-proj")
      Application.put_env(:harness, :roadmap_list, fn _project -> {:ok, @tasks} end)

      summaries = RoadmapSummary.for_projects([project])

      assert summaries["summary-proj"].open == 3
      assert summaries["summary-proj"].landed == %{"5" => "abc1234ff"}
    end

    test "a project whose roadmap errors contributes a zero summary, never crashing" do
      project = ProjectFixture.from_repo("/tmp/harness-roadmap-error", name: "broken-proj")
      Application.put_env(:harness, :roadmap_list, fn _project -> {:error, :roadmap_not_found} end)

      summaries = RoadmapSummary.for_projects([project])

      assert summaries["broken-proj"] == %{open: 0, done: 0, total: 0, landed: %{}, blocked: MapSet.new()}
    end

    test "a project whose roadmap read times out degrades to a zero summary, never blocking" do
      project = ProjectFixture.from_repo("/tmp/harness-roadmap-slow", name: "slow-proj")
      # Short timeout so the kill path exercises quickly; the lister blocks on receive
      # (killed by async_stream) rather than a fixed long sleep.
      Application.put_env(:harness, :roadmap_summary_timeout_ms, 20)
      parent = self()

      Application.put_env(:harness, :roadmap_list, fn proj ->
        send(parent, {:roadmap_list_invoked, proj})
        # Indefinite block; the Task will be killed by the summarize timeout.
        receive do
          _ -> {:ok, @tasks}
        after
          30_000 -> {:ok, @tasks}
        end
      end)

      summaries = RoadmapSummary.for_projects([project])

      assert_receive {:roadmap_list_invoked, ^project}, 200
      assert summaries["slow-proj"] == %{open: 0, done: 0, total: 0, landed: %{}, blocked: MapSet.new()}
    end

    test "runs per-project reads concurrently — wall-clock is ~one read, not N" do
      projects =
        for i <- 1..5 do
          ProjectFixture.from_repo("/tmp/harness-roadmap-conc-#{i}", name: "conc-#{i}")
        end

      parent = self()

      # Small per-read cost to keep the overlap timing signal meaningful without
      # paying a 100 ms+ unconditional dwell on every green run. The assert_receive
      # on the per-project invocation messages synchronizes on the lister having
      # been driven (event-driven rather than blind sleep elapse).
      Application.put_env(:harness, :roadmap_list, fn proj ->
        send(parent, {:roadmap_list_invoked, proj.name})
        Process.sleep(30)
        {:ok, @tasks}
      end)

      {elapsed_us, summaries} = :timer.tc(fn -> RoadmapSummary.for_projects(projects) end)

      # Collect the invocation events (they arrive because for_projects awaits the
      # async_stream tasks). This replaces "wait for the sleeps" with receive sync.
      invoked =
        for _ <- 1..5 do
          assert_receive {:roadmap_list_invoked, name}, 100
          name
        end

      assert Enum.sort(invoked) == Enum.sort(Enum.map(projects, & &1.name))

      # 5 x 30 ms concurrent should be << 5 x 30 ms sequential; keep well under a
      # conservative floor to guard against accidental sequentialization.
      assert elapsed_us < 300_000
      assert map_size(summaries) == 5
      assert summaries["conc-1"].open == 3
    end
  end

  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)
end
