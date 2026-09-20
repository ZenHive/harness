defmodule Harness.Dashboard.InboxTest do
  use Harness.Dashboard.ConnCase, async: false

  alias Harness.AgentAdapter.Codex
  alias Harness.Cron.PendingDispatch
  alias Harness.Dashboard.Inbox
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.Run.LogRecord
  alias Harness.Run.Status

  setup do
    {:ok, source} = Agent.start_link(fn -> facts() end)
    Application.put_env(:harness, :inbox_facts, fn -> {:ok, Agent.get(source, & &1)} end)

    on_exit(fn ->
      Application.delete_env(:harness, :inbox_facts)
      Application.delete_env(:harness, :inbox_action)
    end)

    %{source: source}
  end

  test "counts rows rather than alternative operations and retains hold context" do
    rows = Inbox.compose(facts())
    assert [_, _, _, _, _] = rows

    assert rows |> Enum.flat_map(& &1.actions) |> Enum.sort() ==
             Enum.sort([:approve, :resume, :resume_failed, :rereview, :land, :reland])

    assert Enum.find(rows, &(&1.run_id == "held")).context.hold_reason == :interrupt
  end

  test "committed work, landing and active-attempt guards" do
    base = facts()

    for changes <- [
          %{agent_diff_size: nil},
          %{landed_sha: "landed"},
          %{task_ids: ["2", "9"]}
        ] do
      records = Enum.map(base.records, fn r -> if r.run_id == "failed", do: struct!(r, changes), else: r end)
      refute Enum.any?(Inbox.compose(%{base | records: records}), &(&1.run_id == "failed"))
    end

    assert Inbox.compose(%{base | pending: [], live_runs: [], records: []}) == []
    rows = Inbox.compose(%{base | queued_tasks: %{"inbox" => ["2", "3", "4"]}})
    assert rows |> Enum.flat_map(& &1.actions) |> Enum.sort() == [:approve, :resume]
    rows = Inbox.compose(%{base | landing_branches: %{"inbox" => ["harness/land", "harness/reland"]}})
    refute Enum.any?(rows, &Enum.any?(&1.actions, fn a -> a in [:land, :reland] end))
    project = %{hd(base.projects) | target_branch: nil}
    refute Enum.any?(Inbox.compose(%{base | projects: [project]}), &(:reland in &1.actions or :land in &1.actions))
  end

  test "multiple attempts select exact current identity and do not reuse an old button", %{source: source} do
    row = Enum.find(Inbox.compose(facts()), &(&1.run_id == "failed"))

    Agent.update(source, fn facts ->
      newer = %{Enum.find(facts.records, &(&1.run_id == "failed")) | run_id: "new-failed", started_at: DateTime.utc_now()}
      %{facts | records: [newer | facts.records]}
    end)

    Application.put_env(:harness, :inbox_action, fn _, _ -> flunk("stale operation invoked") end)
    assert {:error, :stale_action} = Inbox.perform(row, "resume_failed")
    {:ok, rows} = Inbox.load()
    assert Enum.any?(rows, &(&1.run_id == "new-failed"))
    refute Enum.any?(rows, &(&1.run_id == "failed"))
  end

  for action <- [:approve, :resume, :resume_failed, :rereview, :land, :reland] do
    test "#{action} invokes the exact row, refreshes and rejects duplicate clicks", %{conn: conn} do
      action = unquote(action)
      parent = self()

      Application.put_env(:harness, :inbox_action, fn name, row ->
        send(parent, {:invoked, name, row})
        {:ok, %{run_id: row.run_id || "approved-run"}}
      end)

      {:ok, view, _} = live(conn, "/harness/inbox")
      render_async(view)
      row = Enum.find(Inbox.compose(facts()), &(action in &1.actions))
      render_click(view, "act", %{"id" => row.id, "action" => to_string(action)})
      assert render_async(view) =~ "Request accepted"
      assert_receive {:invoked, ^action, ^row}
      refute has_element?(view, "button[phx-value-id='#{row.id}']")
      assert render_click(view, "act", %{"id" => row.id, "action" => to_string(action)}) =~ "already submitted"
      refute_received {:invoked, _, _}
    end

    test "#{action} operation errors stay visible and preserve the row", %{conn: conn} do
      action = unquote(action)
      Application.put_env(:harness, :inbox_action, fn _, _ -> {:error, :provider_unavailable} end)
      {:ok, view, _} = live(conn, "/harness/inbox")
      render_async(view)
      row = Enum.find(Inbox.compose(facts()), &(action in &1.actions))
      render_click(view, "act", %{"id" => row.id, "action" => to_string(action)})
      assert render_async(view) =~ "provider_unavailable"
      assert has_element?(view, "button[phx-value-id='#{row.id}']")
    end

    test "#{action} rejects a row whose guard no longer holds", %{source: source} do
      action = unquote(action)
      row = Enum.find(Inbox.compose(facts()), &(action in &1.actions))
      Agent.update(source, &%{&1 | pending: [], live_runs: [], records: []})
      Application.put_env(:harness, :inbox_action, fn _, _ -> flunk("guard bypassed") end)
      assert {:error, :stale_action} = Inbox.perform(row, to_string(action))
    end
  end

  test "project filter, current count, empty state and source errors", %{conn: conn, source: source} do
    {:ok, view, _} = live(conn, "/harness/inbox")
    html = render_async(view)
    assert html =~ "5 unresolved"
    assert html =~ "Hold: interrupt"
    assert html =~ "parked for operator"
    assert render_change(view, "select_project", %{"project" => "other"}) =~ "No unresolved actions"
    assert render_change(view, "select_project", %{"project" => ""}) =~ "5 unresolved"
    render_patch(view, "/harness/inbox")
    Agent.update(source, &%{&1 | pending: []})
    send(view.pid, :inbox_tick)
    assert render_async(view) =~ "4 unresolved"
    Application.put_env(:harness, :inbox_facts, fn -> {:error, :store_unavailable} end)
    send(view.pid, :inbox_tick)
    assert render_async(view) =~ "Inbox unavailable"
    assert has_element?(view, "button[disabled]")
  end

  test "navigation count updates from current facts", %{conn: conn, source: source} do
    {:ok, view, _} = live_isolated(conn, Harness.Dashboard.InboxBadgeLive)
    assert render_async(view) =~ "5</span>"
    Agent.update(source, &%{&1 | pending: []})
    send(view.pid, :inbox_changed)
    assert render_async(view) =~ "4</span>"
    Application.put_env(:harness, :inbox_facts, fn -> {:error, :unavailable} end)
    send(view.pid, :inbox_tick)
    assert render_async(view) =~ "—"
  end

  test "held runs remain actionable even without a roadmap row" do
    facts = facts()

    assert [%{run_id: "held", actions: [:resume]}] =
             Inbox.compose(%{facts | tasks: %{}, pending: []})
  end

  test "unknown operations and cross-project submissions cannot invoke actions", %{conn: conn} do
    row = hd(Inbox.compose(facts()))
    assert {:error, :stale_action} = Inbox.perform(row, "delete")
    {:ok, view, _} = live(conn, "/harness/inbox?project=other")
    render_async(view)
    assert render_click(view, "act", %{"id" => row.id, "action" => "approve"}) =~ "stale"
  end

  test "a deduplicated recovery receipt cannot claim another attempt" do
    row = %{run_id: "source", project: "inbox", task_id: "2"}
    on_exit(fn -> Application.delete_env(:harness, :oban_run_job_lookup) end)

    for source <- ["source", "other-attempt"] do
      Application.put_env(:harness, :oban_run_job_lookup, fn "queued" ->
        {:ok,
         %Oban.Job{
           args: %{
             "run_id" => "queued",
             "project_name" => "inbox",
             "item_id" => "2",
             "dispatch_decision" => %{"source_run_id" => source, "action" => "resume"}
           },
           state: "available"
         }}
      end)

      result = Inbox.verify_recovery({:ok, %{run_id: "queued"}}, row, "resume")

      if source == "source",
        do: assert(result == {:ok, %{run_id: "queued"}}),
        else: assert(result == {:error, {:recovery_receipt_mismatch, "queued"}})
    end
  end

  test "loads real current stores; a missing roadmap does not hide parked approvals" do
    Application.delete_env(:harness, :inbox_facts)
    original = ProjectRegistry.list()
    Enum.each(original, &ProjectRegistry.unregister(&1.name))
    PendingDispatch.reset()

    on_exit(fn ->
      PendingDispatch.reset()
      ProjectRegistry.unregister("inbox-loader")
      Enum.each(original, &ProjectRegistry.register/1)
    end)

    sample = Path.expand("../../fixtures/sample_roadmap", __DIR__)
    project = ProjectFixture.from_repo(sample, name: "inbox-loader")
    :ok = ProjectRegistry.register(project)
    assert {:ok, rows} = Inbox.load()
    assert is_list(rows)
    :ok = ProjectRegistry.unregister(project.name)
    :ok = ProjectRegistry.register(%{project | roadmap_path: Path.join(sample, "absent")})
    {:parked, pending} = PendingDispatch.park(project.name, "7", Codex, %{})
    assert {:ok, loaded} = Inbox.load()
    assert Enum.any?(loaded, &(&1.pending && &1.pending.id == pending.id))
  end

  test "perform surfaces a source error instead of invoking" do
    row = hd(Inbox.compose(facts()))
    Application.put_env(:harness, :inbox_facts, fn -> {:error, :store_unavailable} end)
    Application.put_env(:harness, :inbox_action, fn _, _ -> flunk("invoked on a source error") end)
    assert {:error, :store_unavailable} = Inbox.perform(row, "approve")
  end

  test "refresh retries a source failure and lifecycle messages update counts", %{conn: conn, source: source} do
    {:ok, view, _} = live(conn, "/harness/inbox")
    render_async(view)
    Agent.update(source, &%{&1 | pending: []})
    send(view.pid, {:harness_run_settled, nil})
    assert render_async(view) =~ "4 unresolved"
    send(view.pid, :ignored_lifecycle)
    assert render(view) =~ "4 unresolved"
    Application.put_env(:harness, :inbox_facts, fn -> {:error, :unavailable} end)
    render_click(view, "refresh")
    assert render_async(view) =~ "Use Refresh to retry"
    Application.put_env(:harness, :inbox_facts, fn -> {:ok, Agent.get(source, & &1)} end)
    render_click(view, "refresh")
    refute render_async(view) =~ "Inbox unavailable"
  end

  test "malformed or crashing fact loads stay visible as errors", %{conn: conn} do
    {:ok, view, _} = live(conn, "/harness/inbox")
    render_async(view)
    Application.put_env(:harness, :inbox_facts, fn -> :not_a_result end)
    render_click(view, "refresh")
    assert render_async(view) =~ "Inbox unavailable"
    Application.put_env(:harness, :inbox_facts, fn -> raise "inbox facts crashed" end)
    render_click(view, "refresh")
    assert render_async(view) =~ "Inbox unavailable"
  end

  test "a crashing operation keeps the row and shows the error", %{conn: conn} do
    Application.put_env(:harness, :inbox_action, fn _, _ -> raise "provider crashed" end)
    {:ok, view, _} = live(conn, "/harness/inbox")
    render_async(view)
    row = Enum.find(Inbox.compose(facts()), &(:approve in &1.actions))
    render_click(view, "act", %{"id" => row.id, "action" => "approve"})
    html = render_async(view)
    assert html =~ "Action failed"
    assert has_element?(view, "button[phx-value-id='#{row.id}']")
  end

  test "an unexpected operation result stays visible without implying success", %{conn: conn} do
    Application.put_env(:harness, :inbox_action, fn _, _ -> :not_a_result end)
    {:ok, view, _} = live(conn, "/harness/inbox")
    render_async(view)
    row = Enum.find(Inbox.compose(facts()), &(:approve in &1.actions))
    render_click(view, "act", %{"id" => row.id, "action" => "approve"})
    html = render_async(view)
    assert html =~ "Action failed"
    refute html =~ "Request accepted"
    assert has_element?(view, "button[phx-value-id='#{row.id}']")
  end

  test "real Dispatch guards reject missing runs and approvals" do
    row = %{run_id: "missing-inbox-run", pending: %{id: "missing", parked_at: DateTime.utc_now()}}

    for action <- [:approve, :resume, :resume_failed, :rereview, :land, :reland] do
      assert {:error, :not_found} = Inbox.dispatch(action, row)
    end
  end

  defp facts do
    project = ProjectFixture.from_repo("/tmp/inbox", name: "inbox", landing_policy: :manual, target_branch: "main")

    pending = %PendingDispatch{
      id: "inbox:5",
      project_name: "inbox",
      task_id: "5",
      adapter: Codex,
      env: %{},
      parked_at: ~U[2026-09-20 00:00:00Z],
      opts: [dispatch_decision: %{"action" => "fresh", "reason" => "parked for operator"}]
    }

    %{
      projects: [project],
      tasks: %{
        "inbox" => Enum.map(1..5, &%{"id" => to_string(&1), "status" => if(&1 == 4, do: "blocked", else: "in_progress")})
      },
      live_runs: [
        %Status{run_id: "held", task_id: "1", project_name: "inbox", state: :held, held?: true, hold_reason: :interrupt}
      ],
      records: [record("failed", "2", :failed), record("land", "3", :done), record("reland", "4", :done)],
      pending: [pending],
      queued_tasks: %{},
      landing_branches: %{}
    }
  end

  defp record(id, task, state) do
    %LogRecord{
      batch_id: "batch",
      run_id: id,
      task_id: task,
      task_ids: [task],
      project_name: "inbox",
      adapter: Codex,
      state: state,
      reason: :test,
      verdict: if(state == :done, do: :approve),
      duration_ms: 1,
      agent_diff_size: 1,
      started_at: ~U[2026-09-20 00:00:00Z]
    }
  end
end
