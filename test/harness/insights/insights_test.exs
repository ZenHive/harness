defmodule Harness.InsightsTest do
  use ExUnit.Case, async: false

  alias Harness.Dashboard.RunFeed
  alias Harness.Insights
  alias Harness.Insights.Attempt
  alias Harness.Insights.Store
  alias Harness.Insights.Tick
  alias Harness.Insights.Worker
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.ResultStore.Memory
  alias Harness.ResultStoreContract
  alias Harness.Test.InsightsScriptedWitness

  setup do
    old_models = Application.get_env(:harness, :agent_model)
    Application.put_env(:harness, :agent_model, codex: "gpt-6-astra")

    on_exit(fn ->
      if old_models,
        do: Application.put_env(:harness, :agent_model, old_models),
        else: Application.delete_env(:harness, :agent_model)
    end)

    old = Application.get_env(:harness, :result_store)
    Application.put_env(:harness, :result_store, {Memory, scope: __MODULE__})
    Memory.reset(scope: __MODULE__)
    Store.get("settings")
    :ets.delete_all_objects(Store)
    ProjectRegistry.reset()
    repo = Harness.GitFixture.init_repo()

    for path <- ["roadmap/tasks.toml", "CLAUDE.md", "AGENTS.md", "priv/includes/harness-workflow.md"] do
      File.mkdir_p!(Path.dirname(Path.join(repo, path)))
      File.write!(Path.join(repo, path), "Current project decisions")
    end

    Harness.GitFixture.git!(repo, [
      "add",
      "roadmap/tasks.toml",
      "CLAUDE.md",
      "AGENTS.md",
      "priv/includes/harness-workflow.md"
    ])

    Harness.GitFixture.git!(repo, ["commit", "-qm", "observer context fixture"])
    :ok = ProjectRegistry.register(ProjectFixture.from_repo(repo, name: "insights-test"))
    Application.put_env(:harness, :insights_witness, Harness.Test.InsightsWitness)
    Application.put_env(:harness, :insights_test_owner, self())
    Application.delete_env(:harness, :insights_test_response)

    on_exit(fn ->
      Application.put_env(:harness, :result_store, old)
      Application.delete_env(:harness, :insights_witness)
      Application.delete_env(:harness, :insights_test_owner)
      Application.delete_env(:harness, :insights_test_response)
      :ets.delete_all_objects(Store)
      ProjectRegistry.reset()
    end)

    :ok
  end

  test "disabled independently, validates settings and reports ephemeral scheduling" do
    assert Insights.status()["state"] == "disabled"
    assert Insights.settings()["cadence_minutes"] == 60
    assert Insights.status()["ephemeral"]
    assert {:error, :disabled} = Insights.observe("disabled")
    assert {:error, :disabled} = Insights.observe_now()
    assert {:error, :invalid_settings} = Insights.configure(%{})

    assert {:error, :invalid_settings} =
             Insights.configure(%{"enabled" => true, "cadence_minutes" => 1, "agent" => "codex", "model" => "x"})

    enable()
    assert {:error, :ephemeral_scheduler_unavailable} = Insights.observe_now()
    assert Insights.status()["next_pass"]
  end

  test "publishes revisions once, retains citations and consumes changed late audit evidence" do
    enable()

    record =
      record(
        project_name: "insights-test",
        run_id: "insights-a",
        agent_output: "agent transcript",
        reviewer_output: "reviewer repaired omission"
      )

    :ok = ResultStore.record_run(record)
    assert :ok = Insights.observe("first")
    assert_received {:observed, %{"previous_findings" => []}, "gpt-6-astra"}
    [finding] = Insights.findings()["items"]
    assert :ok = Insights.observe("first")
    refute_received {:observed, _, _}
    assert Enum.count(Insights.history(finding["id"])["revisions"]) == 1
    assert :ok = Insights.observe("unchanged")
    assert Insights.status()["state"] == "no_new_evidence"
    refute_received {:observed, _, _}

    :ok = ResultStore.record_run(%{record | cold_check: %{"passed" => false}, reviewer_output: ""})
    assert :ok = Insights.observe("late-audit")
    assert_received {:observed, %{"previous_findings" => [previous]}, "gpt-6-astra"}
    assert previous["id"] == finding["id"]
    assert Enum.count(Insights.findings()["items"]) == 1
    assert Enum.count(Insights.history(finding["id"])["revisions"]) == 2
    assert Insights.status()["state"] == "successful"
    :ok = ResultStore.delete_run("insights-a")
    assert hd(Insights.history(finding["id"])["revisions"])["citations"] != []
    assert Insights.findings("missing")["items"] == []
    assert Enum.count(Insights.findings("insights-test", "insights-a")["items"]) == 1
  end

  test "failed agents and malformed output preserve successful progress" do
    enable()
    Application.put_env(:harness, :insights_test_response, {:ok, %{"findings" => []}})
    assert :ok = Insights.observe("empty")
    before = Insights.status()["progress"]
    :ok = ResultStore.record_run(record(project_name: "insights-test", run_id: "insights-b"))

    for response <- [{:error, :provider_unavailable}, {:ok, %{"findings" => [nil]}}] do
      Application.put_env(:harness, :insights_test_response, response)
      assert {:error, _} = Insights.observe(Ecto.UUID.generate())
      assert Insights.status()["state"] == "failed"
      assert Insights.status()["progress"] == before
      assert Insights.findings()["items"] == []
    end
  end

  test "successful no-findings differs from no-new-evidence" do
    enable()
    Application.put_env(:harness, :insights_test_response, {:ok, %{"findings" => []}})

    :ok =
      ResultStore.record_run(
        record(
          project_name: "insights-test",
          run_id: "insights-c",
          agent_output: "done",
          reviewer_output: "approved"
        )
      )

    assert :ok = Insights.observe("no-findings")
    assert Insights.status()["state"] == "no_findings"
  end

  test "reads a real active run through status and transcript without lifecycle mutations" do
    :ok = RunFeed.subscribe()
    repo = Harness.GitFixture.init_repo()
    :ok = ProjectRegistry.unregister("insights-test")
    project = ProjectFixture.from_repo(repo, name: "insights-test")
    :ok = ProjectRegistry.register(project)
    gate = Path.join(repo, "release-agent")
    item = %Harness.Roadmap.Item{id: "insights-active", title: "Active evidence", prompt: "Wait for test", agent: :claude}

    {:ok, id, pid} =
      Harness.Run.Supervisor.start_run(item, project, Harness.Test.IdentityFakeAdapter,
        base_dir: Harness.GitFixture.tmp_base(),
        adapter_opts: [command: {:write_then_wait_for_file, gate}],
        terminal_linger: 0,
        total_timeout: 60_000,
        idle_timeout: 60_000,
        lifetime_timeout: 60_000,
        subscriber: self()
      )

    on_exit(fn ->
      monitor = Process.monitor(pid)
      Harness.Run.cancel(id)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 10_000
    end)

    assert_receive {:harness_run_update, %Harness.Run.Status{run_id: ^id}}, 10_000
    enable()
    assert :ok = Insights.observe("active-pass")
    assert_received {:observed, context, "gpt-6-astra"}
    assert Enum.any?(context["sources"], &(&1["run_id"] == id and &1["provisional"]))
    assert Process.alive?(pid)
    refute File.exists?(gate)
    assert :ok = Harness.Run.cancel(id)
  end

  test "MCP exports bounded observations without adding mutation tools to the witness" do
    names = Enum.map(Harness.Manifest.mcp_tools(), & &1.name)
    for name <- ~w(insights-status insights-observe_now insights-findings insights-history), do: assert(name in names)
    assert Worker.timeout(%Oban.Job{}) == 240_000
    assert :ok = Worker.perform(%Oban.Job{args: %{"pass_id" => "disabled-worker"}})
    assert :ok = Tick.perform(%Oban.Job{})
  end

  test "filters before paginating so another project's newest findings cannot hide matches" do
    :ok =
      Store.put_many([
        {"finding/older-match", "finding", %{"id" => "older-match", "projects" => ["match"], "runs" => ["linked-run"]}}
      ])

    :ok =
      Store.put_many(
        for n <- 1..51,
            do: {"finding/other-#{n}", "finding", %{"id" => "other-#{n}", "projects" => ["other"], "runs" => []}}
      )

    assert [%{"id" => "older-match"}] = Insights.findings("match", "linked-run")["items"]
    assert Insights.findings("match")["next_offset"] == nil
  end

  test "a full previous-finding page does not mark a complete evidence window as partial" do
    enable()
    Application.put_env(:harness, :insights_test_response, {:ok, %{"findings" => []}})

    :ok =
      Store.put_many(
        for n <- 1..10 do
          {"finding/prior-#{n}", "finding",
           %{
             "id" => "prior-#{n}",
             "citations" => [],
             "projects" => ["insights-test"],
             "runs" => []
           }}
        end
      )

    :ok =
      ResultStore.record_run(
        record(
          project_name: "insights-test",
          run_id: "complete-window",
          agent_output: "done",
          reviewer_output: "approved"
        )
      )

    assert :ok = Insights.observe("complete-window")
    assert Insights.status()["state"] == "no_findings"
    refute Insights.status()["last_pass"]["partial"]
  end

  test "ephemeral scans also advance beyond a full page and detect later landing changes" do
    enable()
    Application.put_env(:harness, :insights_test_response, {:ok, %{"findings" => []}})

    for n <- 1..15 do
      :ok =
        ResultStore.record_run(
          record(
            project_name: "insights-test",
            run_id: "memory-#{String.pad_leading(to_string(n), 2, "0")}",
            agent_output: "done",
            reviewer_output: "reviewed"
          )
        )
    end

    assert :ok = Insights.observe("memory-1")
    assert Insights.status()["progress"]["cursor"] == "memory-12"
    assert :ok = Insights.observe("memory-2")
    assert Insights.status()["progress"]["cursor"] == ""
    assert :ok = ResultStore.mark_landed("memory-01", "late-sha")
    assert :ok = Insights.observe("memory-3")
    assert Insights.status()["last_pass"]["changed_runs"] == 1
  end

  test "witness exceptions, exits and throws fail without advancing successful progress" do
    enable()
    assert :ok = Insights.observe("checkpoint")
    checkpoint = Store.get("progress")
    :ok = ResultStore.record_run(record(project_name: "insights-test", run_id: "exception-run"))
    Application.put_env(:harness, :insights_witness, InsightsScriptedWitness)
    on_exit(fn -> Application.delete_env(:harness, :insights_script) end)

    for {kind, callback} <- [
          {"exception", fn _, _ -> raise "witness failed" end},
          {"throw", fn _, _ -> throw(:witness_failed) end},
          {"timeout", fn _, _ -> exit(:timeout) end}
        ] do
      Application.put_env(:harness, :insights_script, callback)
      assert {:error, _} = Insights.observe(kind)
      assert Store.get("pass/" <> kind)["state"] == "failed"
      assert Store.get("progress") == checkpoint
      assert Store.get("seen/record/exception-run") == nil
    end
  end

  test "a killed observer and a prior VM incarnation reconcile as interrupted" do
    enable()
    :ok = ResultStore.record_run(record(project_name: "insights-test", run_id: "killed-run"))
    Application.put_env(:harness, :insights_witness, InsightsScriptedWitness)
    on_exit(fn -> Application.delete_env(:harness, :insights_script) end)
    owner = self()

    Application.put_env(:harness, :insights_script, fn _, _ ->
      send(owner, {:witness_waiting, self()})

      receive do
        :finish -> {:ok, %{"findings" => []}}
      end
    end)

    {pid, monitor} = spawn_monitor(fn -> Insights.observe("killed") end)
    # Evidence assembly (git snapshots, store reads) runs before the witness is
    # invoked, so the 100ms assert_receive default is a machine-speed race, not a
    # contract: give the pass room to reach the witness.
    assert_receive {:witness_waiting, witness_pid}, 5_000
    witness_monitor = Process.monitor(witness_pid)
    assert Store.get("pass/killed")["state"] == "observing"
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert_receive {:DOWN, ^witness_monitor, :process, ^witness_pid, :killed}
    assert Insights.status()["state"] == "failed"
    assert Store.get("pass/killed")["error"] == ":interrupted"
    assert Store.get("progress") == nil

    previous_vm = %{
      "id" => "previous-vm",
      "state" => "observing",
      "owner" => Map.put(Attempt.owner(), "boot", "old-vm")
    }

    :ok = Store.put_many([{"pass/previous-vm", "pass", previous_vm}])
    assert Insights.status()["state"] == "failed"
    assert Store.get("pass/previous-vm")["error"] == ":interrupted"
  end

  test "the ownership incarnation differs across actual VMs and is stable within one VM" do
    executable = System.find_executable("elixir")
    assert executable
    paths = for app <- [:harness, :ecto], do: Application.app_dir(app, "ebin")
    argv = Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", ~s|IO.puts(Harness.Insights.Attempt.owner()["boot"])|]
    {first, 0} = System.cmd(executable, argv)
    {second, 0} = System.cmd(executable, argv)
    assert {:ok, _} = Ecto.UUID.cast(String.trim(first))
    assert {:ok, _} = Ecto.UUID.cast(String.trim(second))
    refute first == second
    parent = Attempt.owner()
    child = fn -> Attempt.owner() end |> Task.async() |> Task.await()
    assert parent["boot"] == child["boot"]
    refute parent["pid"] == child["pid"]
  end

  test "legacy and disconnected-node passes recover without interrupting recent work" do
    now = DateTime.to_iso8601(DateTime.utc_now())
    old = "2020-01-01T00:00:00Z"
    remote = Map.put(Attempt.owner(), "node", "disconnected@observer")

    passes = [
      %{"id" => "legacy-recent", "state" => "observing", "at" => now},
      %{"id" => "legacy-old", "state" => "observing", "at" => old},
      %{"id" => "legacy-invalid", "state" => "observing", "at" => "invalid"},
      %{"id" => "legacy-unknown", "state" => "observing"},
      %{"id" => "remote-recent", "state" => "observing", "at" => now, "owner" => remote},
      %{"id" => "remote-old", "state" => "observing", "at" => old, "owner" => remote}
    ]

    :ok = Store.put_many(Enum.map(passes, &{"pass/" <> &1["id"], "pass", &1}))
    assert :ok = Attempt.reconcile()

    for id <- ["legacy-old", "legacy-invalid", "legacy-unknown", "remote-old"],
        do: assert(Store.get("pass/" <> id)["state"] == "failed")

    for id <- ["legacy-recent", "remote-recent"],
        do: assert(Store.get("pass/" <> id)["state"] == "observing")
  end

  test "the pass deadline terminates a blocked witness and records a timeout" do
    enable()
    :ok = ResultStore.record_run(record(project_name: "insights-test", run_id: "timeout-run"))
    Application.put_env(:harness, :insights_witness, InsightsScriptedWitness)
    Application.put_env(:harness, :insights_timeout_ms, 100)

    on_exit(fn ->
      Application.delete_env(:harness, :insights_script)
      Application.delete_env(:harness, :insights_timeout_ms)
    end)

    owner = self()

    Application.put_env(:harness, :insights_script, fn _, _ ->
      send(owner, {:timeout_witness, self()})

      receive do
        :finish -> {:ok, %{"findings" => []}}
      end
    end)

    assert {:error, :observation_timeout} = Insights.observe("deadline")
    assert_received {:timeout_witness, pid}
    refute Process.alive?(pid)
    assert Store.get("pass/deadline")["state"] == "failed"
    assert Store.get("progress") == nil
    assert Store.get("seen/record/timeout-run") == nil
  end

  test "daily cadence survives failed attempts and pending history" do
    assert :ok = Insights.configure(Map.merge(Insights.settings(), %{"enabled" => true, "cadence_minutes" => 1440}))
    :ok = ResultStore.record_run(record(project_name: "insights-test", run_id: "daily-run"))
    :ok = Store.put_many([{"progress", "progress", %{"pending" => true, "last_success" => "2020-01-01T00:00:00Z"}}])
    Application.put_env(:harness, :insights_test_response, {:error, :provider_failed})
    for _ <- 1..3, do: assert({:error, :provider_failed} = Insights.observe("daily"))
    {:ok, next, _} = DateTime.from_iso8601(Insights.status()["next_pass"])
    assert DateTime.diff(next, DateTime.utc_now()) > 86_300
    assert Insights.status()["last_success"] == "2020-01-01T00:00:00Z"
    assert :ok = Tick.perform(%Oban.Job{})
  end

  defp record(options), do: ResultStoreContract.log_record(Keyword.put(options, :started_at, DateTime.utc_now()))

  defp enable, do: Insights.configure(Map.put(Insights.settings(), "enabled", true))
end
