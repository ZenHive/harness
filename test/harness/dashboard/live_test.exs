defmodule Harness.Dashboard.LiveTest do
  # Covers the unit-testable helpers inside `Harness.Dashboard.Live`. Full
  # LiveView mount + render is verified end-to-end in the browser per Task 50's
  # acceptance criteria — the standalone Endpoint is disabled in the test env
  # (`config :harness, :dashboard, enabled: false`) so a `Phoenix.LiveViewTest`
  # mount is not wired up here.

  use ExUnit.Case, async: true

  alias Harness.Dashboard.Live
  alias Harness.FakeAdapter
  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.Roadmap.Item
  alias Harness.Run
  alias Harness.Run.Result
  alias Harness.Run.Status
  alias Phoenix.LiveView.Socket

  defp run_entry(run_id, project_name \\ nil, bucket \\ :in_flight, opts \\ []) do
    status = %Status{
      run_id: run_id,
      task_id: Keyword.get(opts, :task_id, "1"),
      state: Keyword.get(opts, :state, :running),
      repair_attempts: Keyword.get(opts, :repair_attempts, 0),
      verdict_status: Keyword.get(opts, :verdict_status, nil)
    }

    base = %{status: status, bucket: bucket, detail: Keyword.get(opts, :detail, nil)}
    if project_name, do: Map.put(base, :project_name, project_name), else: base
  end

  describe "bucket_counts/1" do
    test "returns zeros when the snapshot has no runs" do
      assert Live.bucket_counts(%{runs: []}) == %{in_flight: 0, repairing: 0, green: 0, red: 0}
    end

    test "groups runs by their classified bucket" do
      snapshot = %{
        runs: [
          run_entry("a", nil, :in_flight),
          run_entry("b", nil, :in_flight),
          run_entry("c", nil, :repairing),
          run_entry("d", nil, :green),
          run_entry("e", nil, :red),
          run_entry("f", nil, :red)
        ]
      }

      assert Live.bucket_counts(snapshot) == %{in_flight: 2, repairing: 1, green: 1, red: 2}
    end
  end

  describe "filter_runs/2 (project filtering)" do
    test "no filter returns the runs unchanged" do
      runs = [run_entry("alpha/r1"), run_entry("beta/r2")]
      assert Live.filter_runs(runs, nil) == runs
    end

    test "filters by the run_id prefix convention (`<project>/<run>`)" do
      runs = [
        run_entry("alpha/r1"),
        run_entry("alpha/r2"),
        run_entry("beta/r1")
      ]

      filtered = Live.filter_runs(runs, "alpha")
      assert Enum.map(filtered, & &1.status.run_id) == ["alpha/r1", "alpha/r2"]
    end

    test "filters by the optional :project_name entry field" do
      runs = [
        run_entry("r-1", "alpha"),
        run_entry("r-2", "alpha"),
        run_entry("r-3", "beta")
      ]

      filtered = Live.filter_runs(runs, "alpha")
      assert Enum.map(filtered, & &1.status.run_id) == ["r-1", "r-2"]
    end
  end

  describe "verdict_label/1" do
    test "maps the three verdict values onto human strings" do
      assert Live.verdict_label(:pass) == "pass"
      assert Live.verdict_label(:fail) == "fail"
      assert Live.verdict_label(nil) == "—"
    end
  end

  describe "killable?/1 (kill-button visibility guard)" do
    test "in-flight states are killable" do
      for state <- [:dispatched, :running, :committing, :verifying] do
        assert Live.killable?(%Status{run_id: "r", task_id: "1", state: state}),
               "expected #{state} to be killable"
      end
    end

    test "settled states hide the kill control" do
      refute Live.killable?(%Status{run_id: "r", task_id: "1", state: :done})
      refute Live.killable?(%Status{run_id: "r", task_id: "1", state: :failed})
    end

    test "a missing run status (detail view, run not found) hides the kill control" do
      refute Live.killable?(nil)
    end
  end

  describe "handle_event(\"kill_run\", ...)" do
    test "routes through Harness.Run.cancel/1 and the run settles :failed" do
      base = GitFixture.tmp_base()
      repo = GitFixture.init_repo()
      project = ProjectFixture.from_repo(repo)

      {:ok, run_id, pid} =
        Run.Supervisor.start_run(item(), project, FakeAdapter,
          base_dir: base,
          adapter_opts: [command: :sleep],
          idle_timeout: 5_000,
          total_timeout: 10_000,
          lifetime_timeout: 30_000,
          terminal_linger: 100,
          subscriber: self()
        )

      ref = Process.monitor(pid)
      socket = socket_with_run(run_id)

      assert {:noreply, %Socket{}} = Live.handle_event("kill_run", %{"run_id" => run_id}, socket)

      assert_receive {:harness_run, ^run_id, %Result{state: :failed, reason: :cancelled}}, 5_000
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end

    test "cancelling an unknown run is a no-op and returns the socket unchanged" do
      socket = socket_with_run("definitely-not-a-run")
      assert {:noreply, ^socket} = Live.handle_event("kill_run", %{"run_id" => "other-run"}, socket)
    end
  end

  defp socket_with_run(run_id) do
    %Socket{assigns: %{__changed__: %{}, run_id: run_id, run_status: nil}}
  end

  defp item do
    %Item{id: "94", title: "Kill button", prompt: "do the thing", agent: :claude}
  end
end
