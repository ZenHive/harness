defmodule Harness.Dashboard.TaskBoardTest do
  @moduledoc """
  Placement and action-eligibility coverage for `Harness.Dashboard.TaskBoard`.

  These tests pin the precedence table: rmap owns Pending/Blocked/Done, live
  and persisted Harness facts own Implementing/Reviewing/Landing, and an older
  attempt cannot complete, hide, or land-lane a task.
  """

  use ExUnit.Case, async: true

  alias Harness.Dashboard.TaskBoard
  alias Harness.ProjectFixture
  alias Harness.Run.Actions.Transcript
  alias Harness.Run.LogRecord
  alias Harness.Run.Status
  alias Harness.TokenUsage

  describe "compose/1 lanes from rmap" do
    test "places pending, blocked, and done from rmap status" do
      lanes = compose(tasks: [pending("1"), blocked("2"), done("3")])

      assert ids(lanes.pending) == ["1"]
      assert ids(lanes.blocked) == ["2"]
      assert ids(lanes.done) == ["3"]
      assert lanes.implementing == []
      assert lanes.reviewing == []
      assert lanes.landing == []
    end

    test "omits superseded tasks rather than inventing a lane" do
      lanes = compose(tasks: [pending("1"), %{"id" => "9", "status" => "superseded", "title" => "dead"}])

      assert ids(lanes.pending) == ["1"]
      refute Enum.any?(TaskBoard.lanes(), fn lane -> "9" in ids(lanes[lane]) end)
    end

    test "pending cards expose ready vs waiting from the rmap ready set" do
      lanes =
        compose(
          tasks: [pending("10", title: "Ready one"), pending("11", title: "Waiting one", depends_on: ["10"])],
          ready_ids: MapSet.new([{"board", "10"}])
        )

      [ready] = Enum.filter(lanes.pending, &(&1.task_id == "10"))
      [waiting] = Enum.filter(lanes.pending, &(&1.task_id == "11"))

      assert ready.dependency == :ready
      assert ready.actions == [:dispatch]
      assert waiting.dependency == :waiting
      assert waiting.actions == []
    end
  end

  describe "compose/1 execution and landing lanes" do
    test "a live running run places an in_progress task in Implementing" do
      lanes =
        compose(
          tasks: [in_progress("4", title: "Wiring")],
          live_runs: [status("run-live", "4", :running, agent: :cursor, model: "grok-4")]
        )

      [card] = lanes.implementing
      assert card.task_id == "4"
      assert card.run_id == "run-live"
      assert card.run_state == :running
      assert card.assignee == "cursor"
      assert card.model == "grok-4"
      assert :hold in card.actions
    end

    test "a live reviewing run places the task in Reviewing" do
      lanes =
        compose(
          tasks: [in_progress("5")],
          live_runs: [status("run-rev", "5", :reviewing)]
        )

      assert ids(lanes.reviewing) == ["5"]
      assert lanes.implementing == []
    end

    test "rmap in_progress with a settled approved unlanded run is Landing" do
      lanes =
        compose(
          tasks: [in_progress("6")],
          records: [record("run-land", "6", :done, verdict: :approve)]
        )

      [card] = lanes.landing
      assert card.task_id == "6"
      assert card.run_id == "run-land"
      assert card.rmap_status == "in_progress"
      assert :rereview in card.actions
    end

    test "a live :done linger of an approved unlanded run is Landing without a persisted record" do
      lanes =
        compose(
          tasks: [in_progress("6")],
          live_runs: [status("run-linger", "6", :done, review_verdict: :approve)]
        )

      [card] = lanes.landing
      assert card.run_id == "run-linger"
      assert card.rmap_status == "in_progress"
      assert lanes.done == []
    end

    test "manual-policy Landing cards expose Land, not Re-land" do
      project = project(landing_policy: :manual, target_branch: "main")

      lanes =
        compose(
          project: project,
          tasks: [in_progress("6")],
          records: [record("run-land", "6", :done, verdict: :approve)],
          landable_projects: MapSet.new(["board"])
        )

      [card] = lanes.landing
      assert :land in card.actions
      refute :reland in card.actions
    end
  end

  describe "compose/1 failed and held facts" do
    test "a held live run is a badge on Implementing or Reviewing, never its own lane" do
      implementing =
        compose(
          tasks: [in_progress("7")],
          live_runs: [
            status("run-hold", "7", :held,
              held?: true,
              state_entered_at: %{running: ~U[2026-09-20 06:00:00Z]}
            )
          ]
        )

      [card] = implementing.implementing
      assert card.held?
      refute card.failed?
      assert :resume in card.actions
      refute :hold in card.actions

      reviewing =
        compose(
          tasks: [in_progress("8")],
          live_runs: [
            status("run-hold-rev", "8", :held,
              held?: true,
              state_entered_at: %{
                running: ~U[2026-09-20 06:00:00Z],
                reviewing: ~U[2026-09-20 06:10:00Z]
              }
            )
          ]
        )

      assert ids(reviewing.reviewing) == ["8"]
      assert hd(reviewing.reviewing).held?
      assert reviewing.implementing == []
    end

    test "a failed in_progress attempt stays Implementing with a failed badge and recovery actions" do
      lanes =
        compose(
          tasks: [in_progress("9")],
          records: [record("run-fail", "9", :failed, reason: :review_stuck)]
        )

      [card] = lanes.implementing
      assert card.failed?
      assert card.run_id == "run-fail"
      assert :resume_failed in card.actions
      assert :rereview in card.actions
    end

    test "a failed pending attempt stays Pending with a failed badge" do
      lanes =
        compose(
          tasks: [pending("12")],
          records: [record("run-fail-p", "12", :failed)],
          ready_ids: MapSet.new([{"board", "12"}])
        )

      [card] = lanes.pending
      assert card.failed?
      assert card.run_id == "run-fail-p"
      assert :dispatch in card.actions
      assert :resume_failed in card.actions
    end
  end

  describe "compose/1 multiple attempts and contradictory sources" do
    test "the newest attempt wins; an older approved record does not land or complete the task" do
      older = record("run-old", "20", :done, verdict: :approve, started_at: ~U[2026-09-01 00:00:00Z])
      newer = record("run-new", "20", :failed, started_at: ~U[2026-09-20 00:00:00Z])

      for records <- [[newer, older], [older, newer]] do
        lanes =
          compose(
            tasks: [in_progress("20", title: "Still open")],
            records: records
          )

        assert ids(lanes.implementing) == ["20"]
        assert lanes.landing == []
        assert lanes.done == []
        [card] = lanes.implementing
        assert card.run_id == "run-new"
        assert card.failed?
        assert card.rmap_status == "in_progress"
      end
    end

    test "rmap done stays Done even when an older unlanded approve exists" do
      lanes =
        compose(
          tasks: [done("21", title: "Shipped")],
          records: [record("run-stale", "21", :done, verdict: :approve)]
        )

      assert ids(lanes.done) == ["21"]
      assert lanes.landing == []
      [card] = lanes.done
      assert card.run_id == "run-stale"
      assert card.rmap_status == "done"
      refute :land in card.actions
    end

    test "rmap pending plus a live run uses the execution lane and keeps rmap status visible" do
      lanes =
        compose(
          tasks: [pending("22", title: "Claimed late")],
          live_runs: [status("run-live-p", "22", :running)]
        )

      assert ids(lanes.implementing) == ["22"]
      assert lanes.pending == []
      [card] = lanes.implementing
      assert card.rmap_status == "pending"
      assert card.run_id == "run-live-p"
    end

    test "rmap blocked wins over a live run; the attempt stays visible" do
      lanes =
        compose(
          tasks: [blocked("23", title: "Land cap")],
          live_runs: [status("run-block-live", "23", :running)],
          records: [record("run-block", "23", :done, verdict: :approve)]
        )

      assert ids(lanes.blocked) == ["23"]
      assert lanes.implementing == []
      [card] = lanes.blocked
      assert card.rmap_status == "blocked"
      assert card.run_id == "run-block-live"
      refute :reland in card.actions
    end

    test "rmap pending plus an older approved unlanded run stays Pending, not Done or Landing" do
      lanes =
        compose(
          tasks: [pending("24")],
          records: [record("run-old-approve", "24", :done, verdict: :approve)]
        )

      assert ids(lanes.pending) == ["24"]
      assert lanes.done == []
      assert lanes.landing == []
      [card] = lanes.pending
      assert card.run_id == "run-old-approve"
      refute :land in card.actions
    end
  end

  test "live snapshots retain coalesced members and place every member in Reviewing" do
    snapshot =
      Transcript.status_snapshot(:reviewing, %{
        run_id: "coalesced-live",
        item: %{id: "40", task_ids: ["40", "41"]},
        project: project(),
        agent_kind: nil,
        requested_model: nil,
        started_at: nil,
        state_entered_at: %{},
        worktree: nil,
        reviewer_adapter: nil,
        recovery_adapter: nil,
        review: nil,
        reason: nil
      })

    lanes = compose(tasks: [in_progress("40"), in_progress("41")], live_runs: [snapshot])
    assert ids(lanes.reviewing) == ["40", "41"]
    assert Enum.all?(lanes.reviewing, &(&1.run_id == "coalesced-live"))
    assert lanes.implementing == []
  end

  test "dependency readiness is independent of headless dispatch eligibility" do
    tasks = [pending("1", depends_on: ["2"]), done("2")]
    assert [card] = compose(tasks: tasks).pending
    assert card.dependency == :ready
    assert card.actions == []
  end

  describe "attempt ordering regressions" do
    test "terminal live attempts compete with older persisted attempts" do
      older = record("old", "1", :done, verdict: :approve, started_at: ~U[2026-09-01 00:00:00Z])
      newer = status("new", "1", :failed, started_at: ~U[2026-09-20 00:00:00Z])
      lanes = compose(tasks: [in_progress("1")], live_runs: [newer], records: [older])
      assert [card] = lanes.implementing
      assert card.run_id == "new"
      assert lanes.landing == []
      assert card.actions == []
    end

    test "multiple live attempts choose active then newest independent of enumeration order" do
      old = status("old", "1", :done, started_at: ~U[2026-09-01 00:00:00Z])
      active = status("active", "1", :reviewing, started_at: ~U[2026-09-20 00:00:00Z])

      for runs <- [[active, old], [old, active]] do
        assert [card] = compose(tasks: [in_progress("1")], live_runs: runs).reviewing
        assert card.run_id == "active"
      end
    end

    test "same-attempt persisted landing witness wins over a terminal live linger" do
      live = status("same", "1", :done, review_verdict: :approve)
      stored = record("same", "1", :done, verdict: :approve, landed_sha: "abc")
      lanes = compose(tasks: [in_progress("1")], live_runs: [live], records: [stored])
      assert [card] = lanes.implementing
      assert card.landed_sha == "abc"
      assert lanes.landing == []
    end

    test "blocked failed attempts cannot expose re-land" do
      lanes = compose(tasks: [blocked("1")], records: [record("failed", "1", :failed)])
      assert [card] = lanes.blocked
      refute :reland in card.actions
    end

    test "Done uses rmap completion dates before unrelated attempt dates or lexical ids" do
      tasks = [Map.put(done("2"), "done_at", "2026-09-20"), Map.put(done("99"), "done_at", "2026-09-01")]

      records = [
        record("old", "2", :done, started_at: ~U[2026-08-01 00:00:00Z]),
        record("new", "99", :done, started_at: ~U[2026-09-20 00:00:00Z])
      ]

      assert [card] = compose(tasks: tasks, records: records, done_limit: 1).done
      assert card.task_id == "2"
    end
  end

  describe "compose/1 card facts and bounds" do
    test "does not fabricate missing assignee, model, tokens, or stage" do
      [card] = compose(tasks: [pending("30")]).pending

      assert card.title == "Task 30"
      assert card.assignee == nil
      assert card.model == nil
      assert card.run_state == nil
      assert card.token_total == nil
      assert card.run_id == nil
    end

    test "uses rmap assignee and model when the selected attempt has none" do
      [card] =
        compose(tasks: [pending("33", assignee: "cursor", model: "composer")]).pending

      assert card.assignee == "cursor"
      assert card.model == "composer"
    end

    test "relays measured token totals from the selected attempt and ignores empty usage" do
      measured =
        record("run-tok", "31", :failed, token_usage: %TokenUsage{total: 12_345, input: 10_000, output: 2_345})

      empty = record("run-empty", "32", :failed, token_usage: TokenUsage.empty())

      lanes =
        compose(
          tasks: [in_progress("31"), in_progress("32")],
          records: [measured, empty]
        )

      by_id = Map.new(lanes.implementing, &{&1.task_id, &1})
      assert by_id["31"].token_total == 12_345
      assert by_id["32"].token_total == nil
    end

    test "bounds Done per project to the newest records" do
      tasks = for i <- 1..5, do: done(Integer.to_string(i), title: "Done #{i}")

      records =
        for i <- 1..5 do
          record("run-d#{i}", Integer.to_string(i), :done,
            verdict: :approve,
            landed_sha: "abc",
            started_at: DateTime.shift(~U[2026-09-01 00:00:00Z], day: i)
          )
        end

      lanes = compose(tasks: tasks, records: Enum.reverse(records), done_limit: 2)

      assert ids(lanes.done) == ["5", "4"]
    end

    test "filter_project/2 keeps one project's cards" do
      alpha = project(name: "alpha")
      beta = project(name: "beta")

      lanes =
        TaskBoard.compose(
          projects: [alpha, beta],
          tasks: %{"alpha" => [pending("1")], "beta" => [pending("2")]},
          ready_ids: MapSet.new()
        )

      filtered = TaskBoard.filter_project(lanes, "alpha")
      assert ids(filtered.pending) == ["1"]
    end

    test "coalesced task_ids index the same attempt onto each member" do
      coalesced = record("run-coal", "40", :failed, task_ids: ["40", "41"])

      lanes =
        compose(
          tasks: [in_progress("40"), in_progress("41")],
          records: [coalesced]
        )

      assert Enum.map(lanes.implementing, & &1.run_id) == ["run-coal", "run-coal"]
    end
  end

  defp compose(opts) do
    project = Keyword.get(opts, :project, project())
    tasks = Keyword.get(opts, :tasks, [])

    TaskBoard.compose(
      projects: [project],
      tasks: %{project.name => tasks},
      ready_ids: Keyword.get(opts, :ready_ids, MapSet.new()),
      live_runs: Keyword.get(opts, :live_runs, []),
      records: Keyword.get(opts, :records, []),
      landable_projects: Keyword.get(opts, :landable_projects, MapSet.new()),
      done_limit: Keyword.get(opts, :done_limit, 20)
    )
  end

  defp project(opts \\ []) do
    ProjectFixture.from_repo("/tmp/harness-task-board", Keyword.merge([name: "board"], opts))
  end

  defp pending(id, opts \\ []), do: task(id, "pending", opts)
  defp in_progress(id, opts \\ []), do: task(id, "in_progress", opts)
  defp blocked(id, opts \\ []), do: task(id, "blocked", opts)
  defp done(id, opts \\ []), do: task(id, "done", opts)

  defp task(id, status, opts) do
    %{
      "id" => id,
      "status" => status,
      "title" => Keyword.get(opts, :title, "Task #{id}"),
      "depends_on" => Keyword.get(opts, :depends_on, []),
      "assignee" => Keyword.get(opts, :assignee),
      "model" => Keyword.get(opts, :model)
    }
  end

  defp status(run_id, task_id, state, opts \\ []) do
    struct!(
      %Status{run_id: run_id, task_id: task_id, state: state, project_name: "board"},
      opts
    )
  end

  defp record(run_id, task_id, state, opts \\ []) do
    %LogRecord{
      batch_id: "batch-#{run_id}",
      run_id: run_id,
      task_id: task_id,
      task_ids: Keyword.get(opts, :task_ids, [task_id]),
      project_name: "board",
      adapter: FakeAdapter,
      state: state,
      reason: Keyword.get(opts, :reason, :approved),
      verdict: Keyword.get(opts, :verdict),
      duration_ms: 1_000,
      started_at: Keyword.get(opts, :started_at),
      landed_sha: Keyword.get(opts, :landed_sha),
      token_usage: Keyword.get(opts, :token_usage, TokenUsage.empty()),
      agent: Keyword.get(opts, :agent),
      model: Keyword.get(opts, :model)
    }
  end

  defp ids(cards), do: Enum.map(cards, & &1.task_id)
end
