defmodule Harness.Dashboard.LiveTest do
  # Covers the unit-testable helpers inside `Harness.Dashboard.Live`. Full
  # LiveView mount + render is verified end-to-end in the browser per Task 50's
  # acceptance criteria — the standalone Endpoint is disabled in the test env
  # (`config :harness, :dashboard, enabled: false`) so a `Phoenix.LiveViewTest`
  # mount is not wired up here.

  use ExUnit.Case, async: true

  alias Harness.AgentRegistry
  alias Harness.Dashboard.Live
  alias Harness.FakeAdapter
  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.ResultStore
  alias Harness.Roadmap.Item
  alias Harness.Run
  alias Harness.Run.LogRecord
  alias Harness.Run.Result
  alias Harness.Run.Status
  alias Phoenix.LiveView.Socket

  defp run_entry(run_id, project_name \\ nil, bucket \\ :in_flight, opts \\ []) do
    status = %Status{
      run_id: run_id,
      task_id: Keyword.get(opts, :task_id, "1"),
      project_name: project_name,
      state: Keyword.get(opts, :state, :running),
      repair_attempts: Keyword.get(opts, :repair_attempts, 0),
      verdict_status: Keyword.get(opts, :verdict_status, nil)
    }

    %{status: status, bucket: bucket, detail: Keyword.get(opts, :detail, nil)}
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
      runs = [run_entry("r-1", "alpha"), run_entry("r-2", "beta")]
      assert Live.filter_runs(runs, nil) == runs
    end

    test "filters by the status's project_name" do
      runs = [
        run_entry("r-1", "alpha"),
        run_entry("r-2", "alpha"),
        run_entry("r-3", "beta")
      ]

      filtered = Live.filter_runs(runs, "alpha")
      assert Enum.map(filtered, & &1.status.run_id) == ["r-1", "r-2"]
    end

    test "a project with no matching runs filters to empty" do
      runs = [run_entry("r-1", "alpha"), run_entry("r-2", "beta")]
      assert Live.filter_runs(runs, "gamma") == []
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

  describe "handle_event(\"select_project\", ...)" do
    test "a project selection patches to the filtered URL" do
      socket = %Socket{assigns: %{__changed__: %{}}}

      {:noreply, socket} = Live.handle_event("select_project", %{"project" => "alpha"}, socket)

      assert {:live, :patch, %{to: to}} = socket.redirected
      assert to == "/harness?project=alpha"
    end

    test "the empty option patches back to the unfiltered URL" do
      socket = %Socket{assigns: %{__changed__: %{}}}

      {:noreply, socket} = Live.handle_event("select_project", %{"project" => ""}, socket)

      assert {:live, :patch, %{to: to}} = socket.redirected
      assert to == "/harness"
    end
  end

  describe "show drill-down (settled-run fallback to ResultStore)" do
    test "rebuilds status and replays the transcript from the persisted record" do
      output = ~s({"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}\n)

      :ok =
        ResultStore.record_run(
          log_record("drill-claude",
            state: :failed,
            reason: :verification_red,
            verdict: :fail,
            agent: :claude,
            agent_output: output
          )
        )

      {:noreply, socket} = Live.handle_params(%{"run_id" => "drill-claude"}, "/harness/runs/drill-claude", show_socket())

      assert %Status{state: :failed, verdict_status: :fail} = socket.assigns.run_status
      assert socket.assigns.transcript == output
      assert socket.assigns.agent_kind == :claude
      refute socket.assigns.transcript_events == []
    end

    test "resolves the parser kind by reverse-mapping the adapter when agent is nil" do
      [{agent, module} | _] = Map.to_list(AgentRegistry.agents())

      :ok = ResultStore.record_run(log_record("drill-byadapter", agent: nil, adapter: module, agent_output: "x\n"))

      {:noreply, socket} =
        Live.handle_params(%{"run_id" => "drill-byadapter"}, "/harness/runs/drill-byadapter", show_socket())

      assert socket.assigns.agent_kind == agent
    end

    test "leaves run_status nil for a run with no live process and no record" do
      {:noreply, socket} =
        Live.handle_params(%{"run_id" => "no-such-run-xyz"}, "/harness/runs/no-such-run-xyz", show_socket())

      assert socket.assigns.run_status == nil
    end
  end

  describe "run-lifecycle feed (show view)" do
    test "an update for the focused run refreshes its status" do
      next = %Status{run_id: "focus-1", task_id: "1", state: :verifying}
      socket = show_lifecycle_socket("focus-1", %Status{run_id: "focus-1", task_id: "1", state: :running})

      {:noreply, socket} = Live.handle_info({:harness_run_update, next}, socket)

      assert socket.assigns.run_status == next
    end

    test "a settled message for the focused run freezes its terminal status" do
      settled = %Status{run_id: "focus-2", task_id: "1", state: :failed, reason: :cancelled}
      socket = show_lifecycle_socket("focus-2", %Status{run_id: "focus-2", task_id: "1", state: :running})

      {:noreply, socket} = Live.handle_info({:harness_run_settled, settled}, socket)

      assert socket.assigns.run_status == settled
    end

    test "a lifecycle message for a different run is ignored" do
      current = %Status{run_id: "focus-3", task_id: "1", state: :running}
      socket = show_lifecycle_socket("focus-3", current)

      other = %Status{run_id: "other", task_id: "9", state: :running}
      {:noreply, socket} = Live.handle_info({:harness_run_update, other}, socket)

      assert socket.assigns.run_status == current
    end
  end

  describe "handle_info(:meta_tick, ...)" do
    test "refreshes sidebar metadata and recomputes the in-memory fleet counts" do
      {:noreply, socket} = Live.handle_info(:meta_tick, meta_tick_socket())

      assert is_list(socket.assigns.projects)
      assert is_list(socket.assigns.adapters)
      assert is_list(socket.assigns.unavailable)
      # Counts self-heal on the slow tick even with no lifecycle event in flight.
      assert is_map(socket.assigns.counts)
      assert is_boolean(socket.assigns.active_empty?)
    end
  end

  defp socket_with_run(run_id) do
    %Socket{assigns: %{__changed__: %{}, run_id: run_id, run_status: nil}}
  end

  defp show_socket do
    %Socket{
      assigns: %{
        __changed__: %{},
        live_action: :show,
        run_id: nil,
        run_status: nil,
        transcript: "",
        transcript_bytes: 0,
        transcript_events: [],
        agent_kind: nil,
        raw_view: false,
        last_seq: 0,
        events_last_seq: 0
      }
    }
  end

  defp show_lifecycle_socket(run_id, run_status) do
    %Socket{
      assigns: %{__changed__: %{}, live_action: :show, run_id: run_id, run_status: run_status}
    }
  end

  defp meta_tick_socket do
    %Socket{
      assigns: %{
        __changed__: %{},
        live_action: :index,
        selected_project: nil,
        projects: [],
        adapters: [],
        unavailable: []
      }
    }
  end

  defp log_record(run_id, opts) do
    reason = Keyword.get(opts, :reason, :passed)

    %LogRecord{
      batch_id: "batch-#{run_id}",
      run_id: run_id,
      task_id: Keyword.get(opts, :task_id, "1"),
      agent: Keyword.get(opts, :agent),
      adapter: Keyword.get(opts, :adapter, FakeAdapter),
      state: Keyword.get(opts, :state, :done),
      reason: reason,
      verdict: Keyword.get(opts, :verdict, :pass),
      duration_ms: 1_000,
      repair_attempts: 0,
      first_attempt_failed_check_count: 0,
      failure_cause: %{reason: reason, failed_checks: []},
      agent_outcome_kind: Keyword.get(opts, :agent_outcome_kind),
      agent_output: Keyword.get(opts, :agent_output, "")
    }
  end

  defp item do
    %Item{id: "94", title: "Kill button", prompt: "do the thing", agent: :claude}
  end
end
