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
  alias Harness.Project
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.Roadmap.Item
  alias Harness.Run
  alias Harness.Run.LogRecord
  alias Harness.Run.Result
  alias Harness.Run.Status
  alias Phoenix.LiveView.Socket

  defp run_entry(run_id, opts) do
    status = %Status{
      run_id: run_id,
      task_id: Keyword.get(opts, :task_id, "1"),
      project_name: Keyword.get(opts, :project_name),
      landed_sha: Keyword.get(opts, :landed_sha),
      state: Keyword.get(opts, :state, :running),
      review_verdict: Keyword.get(opts, :review_verdict, nil)
    }

    %{
      status: status,
      bucket: Keyword.get(opts, :bucket, :in_flight),
      detail: Keyword.get(opts, :detail, nil)
    }
  end

  describe "bucket_counts/1" do
    test "returns zeros when the snapshot has no runs" do
      assert Live.bucket_counts(%{runs: []}) == %{in_flight: 0, repairing: 0, green: 0, red: 0}
    end

    test "groups runs by their classified bucket" do
      snapshot = %{
        runs: [
          run_entry("a", bucket: :in_flight),
          run_entry("b", bucket: :in_flight),
          run_entry("c", bucket: :repairing),
          run_entry("d", bucket: :green),
          run_entry("e", bucket: :red),
          run_entry("f", bucket: :red)
        ]
      }

      assert Live.bucket_counts(snapshot) == %{in_flight: 2, repairing: 1, green: 1, red: 2}
    end
  end

  describe "filter_runs/2 (project filtering)" do
    test "no filter returns the runs unchanged" do
      runs = [run_entry("r-1", project_name: "alpha"), run_entry("r-2", project_name: "beta")]
      assert Live.filter_runs(runs, nil) == runs
    end

    test "filters by the status's project_name" do
      runs = [
        run_entry("r-1", project_name: "alpha"),
        run_entry("r-2", project_name: "alpha"),
        run_entry("r-3", project_name: "beta")
      ]

      filtered = Live.filter_runs(runs, "alpha")
      assert Enum.map(filtered, & &1.status.run_id) == ["r-1", "r-2"]
    end

    test "a project with no matching runs filters to empty" do
      runs = [run_entry("r-1", project_name: "alpha"), run_entry("r-2", project_name: "beta")]
      assert Live.filter_runs(runs, "gamma") == []
    end
  end

  describe "verdict_label/1" do
    test "maps the three reviewer-verdict values onto human strings" do
      assert Live.verdict_label(:approve) == "approved"
      assert Live.verdict_label(:reject) == "rejected"
      assert Live.verdict_label(nil) == "—"
    end
  end

  describe "landed_label/2 + landed_entry?/2 (persisted run fact)" do
    test "a run whose record carries landed_sha renders the short sha and reads landed" do
      entry = run_entry("r-1", project_name: "alpha", bucket: :green, task_id: "1", landed_sha: "abc1234ff")

      assert Live.landed_label(%{}, entry.status) == "✓ abc1234"
      assert Live.landed_entry?(entry, %{})
    end

    test "an unlanded run renders a dash and reads not-landed" do
      entry = run_entry("r-2", project_name: "alpha", bucket: :red, task_id: "2")

      assert Live.landed_label(%{}, entry.status) == "—"
      refute Live.landed_entry?(entry, %{})
    end

    test "empty registry or missing roadmap cannot hide a persisted landed fact" do
      entry = run_entry("r-3", project_name: "alpha", bucket: :green, state: :done, landed_sha: "f00dcafe")

      assert Live.landed_entry?(entry, %{})
      assert Live.landed_label(%{}, entry.status) == "✓ f00dcaf"
    end
  end

  describe "killable?/1 (kill-button visibility guard)" do
    test "in-flight states are killable" do
      for state <- [:dispatched, :running, :committing, :reviewing, :recovering] do
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

  describe "deletable?/1 (delete-button visibility guard)" do
    test "settled states expose the delete control (persisted history record exists)" do
      assert Live.deletable?(%Status{run_id: "r", task_id: "1", state: :done})
      assert Live.deletable?(%Status{run_id: "r", task_id: "1", state: :failed})
    end

    test "in-flight states have no record yet — no delete control" do
      for state <- [:dispatched, :running, :committing, :reviewing, :recovering] do
        refute Live.deletable?(%Status{run_id: "r", task_id: "1", state: state}),
               "expected #{state} to be non-deletable"
      end
    end

    test "a missing run status hides the delete control" do
      refute Live.deletable?(nil)
    end
  end

  describe "resumable?/1 (resume-button visibility guard)" do
    test "a settled :failed run is resumable" do
      assert Live.resumable?(%Status{run_id: "r", task_id: "1", state: :failed})
    end

    test "a :done run is not resumable (it lands / re-lands, not resumes)" do
      refute Live.resumable?(%Status{run_id: "r", task_id: "1", state: :done})
    end

    test "in-flight states are not resumable" do
      for state <- [:dispatched, :running, :committing, :reviewing, :recovering] do
        refute Live.resumable?(%Status{run_id: "r", task_id: "1", state: state}),
               "expected #{state} to be non-resumable"
      end
    end

    test "a missing run status hides the resume control" do
      refute Live.resumable?(nil)
    end
  end

  describe "relandable?/2 (re-land-button visibility guard)" do
    test "a run whose task is blocked in the summaries is re-landable" do
      summaries = %{"proj" => %{open: 1, done: 0, total: 1, landed: %{}, blocked: %{"7" => true}}}

      assert Live.relandable?(
               %Status{run_id: "r", task_id: "7", project_name: "proj", state: :done},
               summaries
             )
    end

    test "a run whose task is not blocked is not re-landable" do
      summaries = %{"proj" => %{open: 0, done: 1, total: 1, landed: %{}, blocked: %{}}}

      refute Live.relandable?(
               %Status{run_id: "r", task_id: "7", project_name: "proj", state: :done},
               summaries
             )
    end

    test "a missing run status hides the re-land control" do
      refute Live.relandable?(nil, %{})
    end
  end

  describe "landable?/3 (manual first-land button visibility guard)" do
    @unlanded %{open: 1, done: 0, total: 1, landed: %{}, blocked: %{}}

    defp done_approved(opts) do
      %Status{
        run_id: "r",
        task_id: Keyword.get(opts, :task_id, "7"),
        project_name: Keyword.get(opts, :project_name, "proj"),
        landed_sha: Keyword.get(opts, :landed_sha),
        state: Keyword.get(opts, :state, :done),
        review_verdict: Keyword.get(opts, :review_verdict, :approve)
      }
    end

    test "an approved, unlanded, unblocked run of a landable project is landable" do
      summaries = %{"proj" => @unlanded}
      landable = MapSet.new(["proj"])

      assert Live.landable?(done_approved(task_id: "7"), summaries, landable)
    end

    test "a project absent from the landable set (no target_branch) hides the button" do
      summaries = %{"proj" => @unlanded}

      refute Live.landable?(done_approved(task_id: "7"), summaries, MapSet.new())
    end

    test "an already-landed run hides the button" do
      summaries = %{"proj" => @unlanded}

      refute Live.landable?(done_approved(task_id: "7", landed_sha: "abc1234"), summaries, MapSet.new(["proj"]))
    end

    test "a blocked task is not landable — that is relandable?/2's case" do
      summaries = %{"proj" => %{@unlanded | blocked: %{"7" => true}}}

      refute Live.landable?(done_approved(task_id: "7"), summaries, MapSet.new(["proj"]))
    end

    test "a rejected verdict hides the button even when the project is landable" do
      summaries = %{"proj" => @unlanded}

      refute Live.landable?(
               done_approved(task_id: "7", review_verdict: :reject),
               summaries,
               MapSet.new(["proj"])
             )
    end

    test "a non-:done state hides the button" do
      summaries = %{"proj" => @unlanded}

      refute Live.landable?(
               done_approved(task_id: "7", state: :failed),
               summaries,
               MapSet.new(["proj"])
             )
    end

    test "a missing run status hides the control" do
      refute Live.landable?(nil, %{}, MapSet.new(["proj"]))
    end
  end

  describe "landable_project_names/1 (manual-policy + target_branch set)" do
    defp project(name, opts) do
      %Project{
        name: name,
        source: nil,
        roadmap_path: "/tmp/#{name}",
        landing_policy: Keyword.get(opts, :landing_policy, :manual),
        target_branch: Keyword.get(opts, :target_branch)
      }
    end

    test "includes a manual-policy project with a configured target_branch" do
      names = Live.landable_project_names([project("a", target_branch: "main")])

      assert MapSet.member?(names, "a")
    end

    test "excludes a manual-policy project with no target_branch (land would bail)" do
      names = Live.landable_project_names([project("a", target_branch: nil)])

      refute MapSet.member?(names, "a")
    end

    test "excludes an empty-string target_branch" do
      names = Live.landable_project_names([project("a", target_branch: "")])

      refute MapSet.member?(names, "a")
    end

    test "excludes an auto-policy project — the train lands those, not the button" do
      names = Live.landable_project_names([project("a", landing_policy: :auto, target_branch: "main")])

      refute MapSet.member?(names, "a")
    end

    test "an empty project list yields an empty set" do
      assert Live.landable_project_names([]) == MapSet.new()
    end
  end

  describe "live_edited_files/1 (in-flight edited-file harvest)" do
    test "surfaces string-keyed file_path / path tool args, first-seen and deduped" do
      events = [
        {:assistant_text, %{text: "working"}},
        {:assistant_tool_use, %{id: "1", name: "Edit", input: %{"file_path" => "lib/a.ex"}}},
        {:assistant_tool_use, %{id: "2", name: "Read", input: %{"path" => "lib/b.ex"}}},
        {:assistant_tool_use, %{id: "3", name: "Edit", input: %{"file_path" => "lib/a.ex"}}},
        {:tool_result, %{tool_use_id: "1", content: "ok"}}
      ]

      assert Live.live_edited_files(events) == ["lib/a.ex", "lib/b.ex"]
    end

    test "ignores tool calls whose input carries no file path (e.g. codex command_execution)" do
      events = [
        {:assistant_tool_use, %{id: "1", name: "command_execution", input: %{command: "mix test"}}},
        {:assistant_tool_use, %{id: "2", name: "Bash", input: %{"command" => "ls"}}}
      ]

      assert Live.live_edited_files(events) == []
    end

    test "an empty event stream yields no edited files" do
      assert Live.live_edited_files([]) == []
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

  # The "delete_run" handler's stream_delete_by_dom_id needs a fully-mounted
  # LiveView socket (lifecycle hooks), which the disabled-Endpoint test env can't
  # build — the full click→remove path is browser-verified per the moduledoc. Its
  # pure view-state core (which entries survive a delete) is prune_history/2:
  describe "prune_history/2 (delete-run history pruning)" do
    test "drops every entry for the targeted run_id, keeping order of the rest" do
      keep1 = run_entry("run-a", state: :done)
      drop = run_entry("run-drop", state: :failed)
      keep2 = run_entry("run-b", state: :failed)

      assert Live.prune_history([keep1, drop, keep2], "run-drop") == [keep1, keep2]
    end

    test "removing the only entry yields an empty history" do
      assert Live.prune_history([run_entry("run-x", state: :failed)], "run-x") == []
    end

    test "a run_id that isn't present leaves the list unchanged" do
      entries = [run_entry("run-a", state: :done)]
      assert Live.prune_history(entries, "absent") == entries
    end
  end

  describe "mark_history_landed/3" do
    test "stores the landed sha on the matching history status only" do
      target = run_entry("run-landed", state: :done)
      other = run_entry("run-other", state: :done)

      [updated, untouched] = Live.mark_history_landed([target, other], "run-landed", "abc1234ff")

      assert updated.status.landed_sha == "abc1234ff"
      assert untouched.status.landed_sha == nil
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
            reason: {:review_rejected, "fake review: reject"},
            verdict: :reject,
            agent: :claude,
            agent_output: output
          )
        )

      {:noreply, socket} = Live.handle_params(%{"run_id" => "drill-claude"}, "/harness/runs/drill-claude", show_socket())

      assert %Status{state: :failed, review_verdict: :reject} = socket.assigns.run_status
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

  describe "show drill-down — changed files (RunDiff)" do
    test "assigns the git diff for a settled run whose branch exists" do
      repo = GitFixture.init_repo()
      run_id = "diff-#{System.unique_integer([:positive])}"

      GitFixture.git!(repo, ["checkout", "-q", "-b", "harness/#{run_id}"])
      File.write!(Path.join(repo, "new.ex"), "defmodule New do\nend\n")
      GitFixture.git!(repo, ["add", "."])
      GitFixture.git!(repo, ["commit", "-q", "-m", "work"])
      GitFixture.git!(repo, ["checkout", "-q", "main"])

      name = "live-diff-#{System.unique_integer([:positive])}"
      :ok = ProjectRegistry.register(ProjectFixture.from_repo(repo, name: name))
      on_exit(fn -> ProjectRegistry.unregister(name) end)

      :ok = ResultStore.record_run(log_record(run_id, project_name: name, agent: :claude, agent_output: "x\n"))

      {:noreply, socket} =
        Live.handle_params(%{"run_id" => run_id}, "/harness/runs/#{run_id}", show_socket())

      assert {:ok, diff} = socket.assigns.run_diff
      assert Enum.any?(diff.files, &(&1.path == "new.ex"))
    end

    test "leaves run_diff nil for a run with no live process and no record" do
      {:noreply, socket} =
        Live.handle_params(%{"run_id" => "absent-diff-xyz"}, "/harness/runs/absent-diff-xyz", show_socket())

      assert socket.assigns.run_diff == nil
    end
  end

  describe "run-lifecycle feed (show view)" do
    test "an update for the focused run refreshes its status" do
      next = %Status{run_id: "focus-1", task_id: "1", state: :reviewing}
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
      # Counts self-heal on the slow tick even with no lifecycle event in flight.
      assert is_map(socket.assigns.counts)
      assert is_boolean(socket.assigns.active_empty?)
    end
  end

  describe "header labels — agent_label/2 and token_label/2" do
    test "agent_label prefers the resolved adapter, falls back to the status field, then —" do
      # Resolved kind (available from run start) wins over the Status field
      # (nil until termination) — this is the fix for the perpetual "nil".
      assert Live.agent_label(:cursor, nil) == "cursor"
      assert Live.agent_label(nil, :claude) == "claude"
      assert Live.agent_label(nil, nil) == "—"
    end

    test "stage_agent_label names the reviewer while reviewing, recovery while recovering, else implementer" do
      base = %Status{run_id: "r", task_id: "1", state: :running, agent: :cursor}

      # Non-stage states show the implementer.
      assert Live.stage_agent_label(base) == "cursor"
      assert Live.stage_agent_label(%{base | state: :done}) == "cursor"

      # Reviewing shows the reviewer, not the implementer.
      assert Live.stage_agent_label(%{base | state: :reviewing, reviewer_adapter: :claude}) == "claude"
      # Recovering shows the recovery agent.
      assert Live.stage_agent_label(%{base | state: :recovering, recovery_adapter: :codex}) == "codex"

      # Reviewing with no reviewer resolved yet falls back to the implementer.
      assert Live.stage_agent_label(%{base | state: :reviewing, reviewer_adapter: nil}) == "cursor"
    end

    test "token_label parses the transcript and renders the total" do
      transcript = ~s({"type":"result","usage":{"input_tokens":7,"output_tokens":44}}\n)
      assert Live.token_label(:claude, transcript) == "51"
    end

    test "token_label renders — for an agent that reports no usage" do
      assert Live.token_label(:grok, ~s({"type":"text","data":"hi"}\n)) == "—"
      assert Live.token_label(nil, "plain text") == "—"
    end

    test "model_label prefers the stored model, falls back to live transcript parse, then —" do
      transcript = ~s({"type":"system","subtype":"init","model":"Composer 2.5 Fast"}\n)
      # Stored value (settled record) wins.
      assert Live.model_label(:cursor, "claude-opus-4-8", transcript) == "claude-opus-4-8"
      # No stored value → parse the live transcript (claude/cursor report it early).
      assert Live.model_label(:cursor, nil, transcript) == "Composer 2.5 Fast"
      # Agent that never reports a model → requested fallback with a hint.
      assert Live.model_label(:grok, "grok-3", ~s({"type":"text","data":"hi"}\n)) == "grok-3 (requested)"
      assert Live.model_label(:grok, nil, ~s({"type":"text","data":"hi"}\n)) == "—"
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
        projects: []
      }
    }
  end

  defp log_record(run_id, opts) do
    %LogRecord{
      batch_id: "batch-#{run_id}",
      run_id: run_id,
      task_id: Keyword.get(opts, :task_id, "1"),
      project_name: Keyword.get(opts, :project_name),
      agent: Keyword.get(opts, :agent),
      adapter: Keyword.get(opts, :adapter, FakeAdapter),
      state: Keyword.get(opts, :state, :done),
      reason: Keyword.get(opts, :reason, :approved),
      verdict: Keyword.get(opts, :verdict, :approve),
      landed_sha: Keyword.get(opts, :landed_sha),
      duration_ms: 1_000,
      review_iterations: 0,
      agent_outcome_kind: Keyword.get(opts, :agent_outcome_kind),
      agent_output: Keyword.get(opts, :agent_output, "")
    }
  end

  defp item do
    %Item{id: "94", title: "Kill button", prompt: "do the thing", agent: :claude}
  end
end
