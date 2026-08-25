defmodule Harness.Cron.RoadmapPollerTest do
  # async: false because tests mutate AgentRegistry, ProjectRegistry, and app env seams.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Harness.AgentAdapter.Codex
  alias Harness.AgentRegistry
  alias Harness.Cron.Orchestrator
  alias Harness.Cron.PendingDispatch
  alias Harness.Cron.RoadmapPoller
  alias Harness.Cron.Settings
  alias Harness.ModelAvailability
  alias Harness.Notification.Event
  alias Harness.Oban, as: HarnessOban
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.Run.Status
  alias Harness.Run.Worker
  alias Harness.Test.CaptureSink
  alias Harness.Test.SettingsStoreMemory
  alias Oban.Plugins.Cron

  setup do
    prior_cron_polling = Application.get_env(:harness, :cron_polling)
    prior_sinks = Application.get_env(:harness, :notification_sinks)

    SettingsStoreMemory.reset(scope: :test_default)
    AgentRegistry.reset()
    ProjectRegistry.reset()
    PendingDispatch.reset()

    on_exit(fn ->
      restore_env(:cron_polling, prior_cron_polling)
      restore_env(:notification_sinks, prior_sinks)
      SettingsStoreMemory.reset(scope: :test_default)
      Application.delete_env(:harness, :oban_insert)
      Application.delete_env(:harness, :roadmap_ready)
      Application.delete_env(:harness, :cron_orchestrator)
      Application.delete_env(:harness, :test_capture_pid)
      Application.delete_env(:harness, :live_run_statuses)
      PendingDispatch.reset()
    end)

    :ok
  end

  test "master autonomy disabled by default, but the cron plugin still registers" do
    # The tick is always scheduled (Task 109): decoupling "tick is scheduled"
    # (unconditional) from "tick dispatches" (the runtime master gate) is what
    # lets the dashboard toggle take effect with no restart.
    refute RoadmapPoller.enabled?()
    assert Enum.any?(HarnessOban.oban_opts()[:plugins], &cron_plugin?/1)
    assert {:cron, 1} in HarnessOban.oban_opts()[:queues]
  end

  test "cron plugin carries the configured schedule" do
    assert :ok = Settings.set_master(true, "test")
    assert :ok = Settings.set_schedule("hourly", "test")

    assert RoadmapPoller.enabled?()
    assert {:cron, 1} in HarnessOban.oban_opts()[:queues]

    assert {Cron, cron_opts} =
             Enum.find(HarnessOban.oban_opts()[:plugins], &cron_plugin?/1)

    assert cron_opts[:timezone] == HarnessOban.cron_timezone()

    crontab = cron_crontab()

    assert {"0 * * * *", RoadmapPoller, [queue: :cron, max_attempts: 1]} in crontab
  end

  test "disabled poller does not read the roadmap or enqueue work" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-cron-disabled", name: "cron-disabled")
    assert :ok = ProjectRegistry.register(project)

    Application.put_env(:harness, :roadmap_ready, fn _project ->
      send(parent, :read)
      {:ok, [task("51", nil)]}
    end)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      send(parent, {:inserted, Ecto.Changeset.apply_action!(changeset, :insert)})
      {:ok, Ecto.Changeset.apply_action!(changeset, :insert)}
    end)

    assert :ok = RoadmapPoller.perform(%Oban.Job{})
    refute_received :read
    refute_received {:inserted, _job}
  end

  test "N>=2 dispatchable tasks route through the orchestrator; only its plan is enqueued" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-cron-enabled", name: "cron-enabled", concurrency_cap: 10)
    assert :ok = ProjectRegistry.register(project)

    enable_project("cron-enabled")

    # 51 has no assignee (undispatchable — never defaulted to claude); 52/53/54
    # carry intent, so the gate (N=3) wakes the orchestrator.
    Application.put_env(:harness, :roadmap_ready, fn p ->
      send(parent, {:ready, p.name})
      {:ok, [task("51", nil), task("52", "codex"), task("53", "cursor"), task("54", "grok")]}
    end)

    # The orchestrator dispatches 52+53 this wave and defers 54 (its judgment);
    # harness enqueues exactly that — not 54, not the undispatchable 51.
    Application.put_env(:harness, :cron_orchestrator, fn p, ready ->
      send(parent, {:planned, p.name, Enum.map(ready, & &1["id"])})

      {:ok,
       %Orchestrator{
         dispatch: [%{task_id: "52", adapter: "codex"}, %{task_id: "53", adapter: "cursor"}],
         skip: [%{task_id: "54", disposition: "defer", reason: "later wave"}]
       }}
    end)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      job = Ecto.Changeset.apply_action!(changeset, :insert)
      send(parent, {:inserted, job})
      {:ok, job}
    end)

    assert :ok = RoadmapPoller.perform(%Oban.Job{})

    assert_received {:ready, "cron-enabled"}
    # Only the dispatchable set (52/53/54) is handed to the orchestrator; 51 is not.
    assert_received {:planned, "cron-enabled", ["52", "53", "54"]}

    assert_received {:inserted,
                     %Oban.Job{
                       args: %{
                         project_name: "cron-enabled",
                         item_id: "52",
                         adapter_module: "Elixir.Harness.AgentAdapter.Codex",
                         env: %{"OPENAI_API_KEY" => false}
                       },
                       meta: %{harness_stage: "cron_poll"},
                       queue: "project_cron-enabled",
                       worker: "Harness.Run.Worker"
                     }}

    assert_received {:inserted,
                     %Oban.Job{
                       args: %{item_id: "53", adapter_module: "Elixir.Harness.AgentAdapter.Cursor"} = cursor_args
                     }}

    refute Map.has_key?(cursor_args, :env)

    # Deferred + undispatchable tasks are never enqueued.
    refute_received {:inserted, %Oban.Job{args: %{item_id: "54"}}}
    refute_received {:inserted, %Oban.Job{args: %{item_id: "51"}}}
  end

  test "write-set collisions serialize a ready set before parallel dispatch" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-cron-collision", name: "cron-collision", concurrency_cap: 10)
    assert :ok = ProjectRegistry.register(project)

    enable_project("cron-collision")

    Application.put_env(:harness, :roadmap_ready, fn _p ->
      {:ok,
       [
         Map.put(task("52", "codex"), "files_to_modify", ["src/x"]),
         Map.put(task("53", "cursor"), "touches", ["src/x"]),
         Map.put(task("54", "grok"), "files_to_modify", ["src/x"])
       ]}
    end)

    Application.put_env(:harness, :cron_orchestrator, fn _p, _ready ->
      send(parent, :orchestrator_called)
      {:error, :should_not_plan_colliding_wave}
    end)

    capture_inserts(parent)

    log = capture_log(fn -> assert :ok = RoadmapPoller.perform(%Oban.Job{}) end)

    assert log =~ "serialized tasks 52, 53, 54"
    assert log =~ "src/x"
    refute_received :orchestrator_called
    assert_received {:inserted, %{item_id: "52"}}
    refute_received {:inserted, %{item_id: "53"}}
    refute_received {:inserted, %{item_id: "54"}}
  end

  test "exactly one dispatchable task is dispatched directly — the orchestrator is not woken" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-cron-single", name: "cron-single", concurrency_cap: 10)
    assert :ok = ProjectRegistry.register(project)

    enable_project("cron-single")

    # One real assignee + one undispatchable nil → N=1 → direct dispatch, no agent.
    Application.put_env(:harness, :roadmap_ready, fn _p ->
      {:ok, [task("51", nil), task("52", "codex")]}
    end)

    Application.put_env(:harness, :cron_orchestrator, fn _p, _ready ->
      send(parent, :orchestrator_woken)
      {:ok, %Orchestrator{dispatch: [], skip: []}}
    end)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      job = Ecto.Changeset.apply_action!(changeset, :insert)
      send(parent, {:inserted, job.args})
      {:ok, job}
    end)

    assert :ok = RoadmapPoller.perform(%Oban.Job{})

    refute_received :orchestrator_woken
    assert_received {:inserted, %{item_id: "52", adapter_module: "Elixir.Harness.AgentAdapter.Codex"}}
    refute_received {:inserted, %{item_id: "51"}}
  end

  test "zero dispatchable tasks dispatch nothing and never wake the orchestrator" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-cron-zero", name: "cron-zero", concurrency_cap: 10)
    assert :ok = ProjectRegistry.register(project)

    enable_project("cron-zero")

    # All undispatchable: a human task and an unrouted one.
    Application.put_env(:harness, :roadmap_ready, fn _p ->
      {:ok, [task("51", "human"), task("52", nil)]}
    end)

    Application.put_env(:harness, :cron_orchestrator, fn _p, _ready ->
      send(parent, :orchestrator_woken)
      {:ok, %Orchestrator{dispatch: [], skip: []}}
    end)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      send(parent, {:inserted, Ecto.Changeset.apply_action!(changeset, :insert).args})
      {:ok, Ecto.Changeset.apply_action!(changeset, :insert)}
    end)

    assert :ok = RoadmapPoller.perform(%Oban.Job{})

    refute_received :orchestrator_woken
    refute_received {:inserted, _args}
  end

  test "an orchestrator that returns no plan dispatches nothing this tick" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-cron-noplan", name: "cron-noplan", concurrency_cap: 10)
    assert :ok = ProjectRegistry.register(project)

    enable_project("cron-noplan")

    Application.put_env(:harness, :roadmap_ready, fn _p ->
      {:ok, [task("52", "codex"), task("53", "cursor")]}
    end)

    # A malformed/agent-failed plan must NOT fall back to a blind fan-out.
    Application.put_env(:harness, :cron_orchestrator, fn _p, _ready -> {:error, :missing} end)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      send(parent, {:inserted, Ecto.Changeset.apply_action!(changeset, :insert).args})
      {:ok, Ecto.Changeset.apply_action!(changeset, :insert)}
    end)

    assert :ok = RoadmapPoller.perform(%Oban.Job{})

    refute_received {:inserted, _args}
  end

  test "operator config can disable subscription scrubs for metered API-key agents" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-cron-metered", name: "cron-metered", concurrency_cap: 10)
    assert :ok = ProjectRegistry.register(project)

    # claude is reviewer/implementer-disabled by the in-code seed; this test is
    # about scrub config for a metered agent, so enable claude explicitly.
    assert :ok = Harness.Agent.Settings.set_enabled(:claude, true, "test")

    Application.put_env(:harness, :cron_polling, subscription_env_scrubs: %{claude: false, codex: %{}})
    enable_project("cron-metered")

    Application.put_env(:harness, :roadmap_ready, fn _p ->
      {:ok, [task("51", "claude"), task("52", "codex")]}
    end)

    # Two dispatchable tasks → orchestrator path; the scrub-disable config applies
    # at enqueue regardless of which path selected the task.
    Application.put_env(:harness, :cron_orchestrator, fn _p, _ready ->
      {:ok,
       %Orchestrator{
         dispatch: [%{task_id: "51", adapter: "claude"}, %{task_id: "52", adapter: "codex"}],
         skip: []
       }}
    end)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      job = Ecto.Changeset.apply_action!(changeset, :insert)
      send(parent, {:inserted, job.args})
      {:ok, job}
    end)

    assert :ok = RoadmapPoller.perform(%Oban.Job{})

    assert_received {:inserted, %{item_id: "51", adapter_module: "Elixir.Harness.AgentAdapter.Claude"} = claude_args}
    assert_received {:inserted, %{item_id: "52", adapter_module: "Elixir.Harness.AgentAdapter.Codex"} = codex_args}
    refute Map.has_key?(claude_args, :env)
    refute Map.has_key?(codex_args, :env)
  end

  test "enabled tick skips human-assigned tasks" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-cron-human", name: "cron-human", concurrency_cap: 10)
    assert :ok = ProjectRegistry.register(project)

    enable_project("cron-human")

    Application.put_env(:harness, :roadmap_ready, fn _p ->
      {:ok, [task("51", "human"), task("52", "codex")]}
    end)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      job = Ecto.Changeset.apply_action!(changeset, :insert)
      send(parent, {:inserted, job.args})
      {:ok, job}
    end)

    assert :ok = RoadmapPoller.perform(%Oban.Job{})

    refute_received {:inserted, %{item_id: "51"}}
    assert_received {:inserted, %{item_id: "52", adapter_module: "Elixir.Harness.AgentAdapter.Codex"}}
  end

  describe "duplicate dispatch guard" do
    test "two ticks inside one live-run window enqueue a task once" do
      parent = self()
      live? = start_supervised!({Agent, fn -> false end})
      project = ProjectFixture.from_repo("/tmp/harness-cron-live-dedup", name: "cron-live-dedup", concurrency_cap: 10)
      assert :ok = ProjectRegistry.register(project)

      enable_project("cron-live-dedup")
      Application.put_env(:harness, :roadmap_ready, fn _p -> {:ok, [task("52", "codex")]} end)

      Application.put_env(:harness, :live_run_statuses, fn ->
        if Agent.get(live?, & &1) do
          [%Status{run_id: "run-live-52", project_name: "cron-live-dedup", task_id: "52", state: :running}]
        else
          []
        end
      end)

      Application.put_env(:harness, :oban_insert, fn changeset ->
        job = Ecto.Changeset.apply_action!(changeset, :insert)
        send(parent, {:inserted, job.args})
        Agent.update(live?, fn _ -> true end)
        {:ok, job}
      end)

      assert :ok = RoadmapPoller.perform(%Oban.Job{})
      assert :ok = RoadmapPoller.perform(%Oban.Job{})

      assert_received {:inserted, %{project_name: "cron-live-dedup", item_id: "52"}}
      refute_received {:inserted, %{project_name: "cron-live-dedup", item_id: "52"}}
    end

    test "a tick after the prior run settled dispatches the pending task again" do
      parent = self()
      project = ProjectFixture.from_repo("/tmp/harness-cron-settled-redo", name: "cron-settled-redo", concurrency_cap: 10)
      assert :ok = ProjectRegistry.register(project)

      enable_project("cron-settled-redo")
      Application.put_env(:harness, :roadmap_ready, fn _p -> {:ok, [task("52", "codex")]} end)

      Application.put_env(:harness, :live_run_statuses, fn ->
        [%Status{run_id: "run-failed-52", project_name: "cron-settled-redo", task_id: "52", state: :failed}]
      end)

      Application.put_env(:harness, :oban_insert, fn changeset ->
        job = Ecto.Changeset.apply_action!(changeset, :insert)
        send(parent, {:inserted, job.args})
        {:ok, job}
      end)

      assert :ok = RoadmapPoller.perform(%Oban.Job{})
      assert :ok = RoadmapPoller.perform(%Oban.Job{})

      assert_received {:inserted, %{project_name: "cron-settled-redo", item_id: "52"}}
      assert_received {:inserted, %{project_name: "cron-settled-redo", item_id: "52"}}
    end

    test "a live run for one task does not block a different pending task" do
      parent = self()

      project =
        ProjectFixture.from_repo("/tmp/harness-cron-different-task", name: "cron-different-task", concurrency_cap: 10)

      assert :ok = ProjectRegistry.register(project)

      enable_project("cron-different-task")
      Application.put_env(:harness, :roadmap_ready, fn _p -> {:ok, [task("53", "codex")]} end)

      Application.put_env(:harness, :live_run_statuses, fn ->
        [%Status{run_id: "run-live-52", project_name: "cron-different-task", task_id: "52", state: :running}]
      end)

      Application.put_env(:harness, :oban_insert, fn changeset ->
        job = Ecto.Changeset.apply_action!(changeset, :insert)
        send(parent, {:inserted, job.args})
        {:ok, job}
      end)

      assert :ok = RoadmapPoller.perform(%Oban.Job{})

      assert_received {:inserted, %{project_name: "cron-different-task", item_id: "53"}}
    end

    @tag :integration
    test "an unfinished Oban run job blocks duplicate enqueue for the same task" do
      start_supervised!(Harness.Repo)
      :ok = Sandbox.checkout(Harness.Repo)

      parent = self()
      project = ProjectFixture.from_repo("/tmp/harness-cron-oban-dedup", name: "cron-oban-dedup", concurrency_cap: 10)
      assert :ok = ProjectRegistry.register(project)

      enable_project("cron-oban-dedup")
      Application.put_env(:harness, :roadmap_ready, fn _p -> {:ok, [task("52", "codex")]} end)

      args = %{
        project_name: project.name,
        item_id: "52",
        adapter_module: Atom.to_string(Codex)
      }

      {:ok, %Oban.Job{state: "available"}} =
        Harness.Repo.insert(Worker.new(args, queue: HarnessOban.queue_name(project)))

      Application.put_env(:harness, :oban_insert, fn changeset ->
        job = Ecto.Changeset.apply_action!(changeset, :insert)
        send(parent, {:inserted, job.args})
        {:ok, job}
      end)

      assert :ok = RoadmapPoller.perform(%Oban.Job{})

      refute_received {:inserted, %{project_name: "cron-oban-dedup", item_id: "52"}}
      assert HarnessOban.unfinished_run_job?(project, "52")
    end
  end

  test "a planned task routed to an unavailable agent is skipped; the rest of the wave dispatches" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-cron-unavailable", name: "cron-unavailable", concurrency_cap: 10)
    assert :ok = ProjectRegistry.register(project)
    # Grok is out; the codex-routed task is unaffected. The availability gate
    # (AgentRegistry.select/2) is mechanical and applies on the planned path too.
    assert :ok = AgentRegistry.mark_unavailable(Harness.AgentAdapter.Grok, :quota)

    enable_project("cron-unavailable")

    Application.put_env(:harness, :roadmap_ready, fn _p ->
      {:ok, [task("51", "grok"), task("52", "codex")]}
    end)

    Application.put_env(:harness, :cron_orchestrator, fn _p, _ready ->
      {:ok,
       %Orchestrator{
         dispatch: [%{task_id: "51", adapter: "grok"}, %{task_id: "52", adapter: "codex"}],
         skip: []
       }}
    end)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      job = Ecto.Changeset.apply_action!(changeset, :insert)
      send(parent, {:inserted, job.args})
      {:ok, job}
    end)

    assert :ok = RoadmapPoller.perform(%Oban.Job{})

    refute_received {:inserted, %{item_id: "51"}}
    assert_received {:inserted, %{item_id: "52", adapter_module: "Elixir.Harness.AgentAdapter.Codex"}}
  end

  test "an adapter-unavailable task is suppressed until its adapter becomes available" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-cron-adapter-unavailable", name: "cron-adapter-unavailable")
    assert :ok = ProjectRegistry.register(project)

    enable_project("cron-adapter-unavailable")
    Application.put_env(:harness, :roadmap_ready, fn _p -> {:ok, [task("130", "codex")]} end)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      job = Ecto.Changeset.apply_action!(changeset, :insert)
      send(parent, {:inserted, job.args})
      {:ok, job}
    end)

    assert :ok = AgentRegistry.mark_unavailable(Codex, :quota)

    log = capture_log(fn -> assert :ok = RoadmapPoller.perform(%Oban.Job{}) end)

    assert log =~ "task 130 dispatch suppressed"
    assert log =~ "adapter=Harness.AgentAdapter.Codex"
    assert log =~ "reason={:adapter_unavailable, :codex, {:no_available_agent, [Harness.AgentAdapter.Codex]}}"
    refute_received {:inserted, %{item_id: "130"}}

    assert :ok = AgentRegistry.mark_available(Codex)
    assert :ok = RoadmapPoller.perform(%Oban.Job{})

    assert_received {:inserted, %{item_id: "130", adapter_module: "Elixir.Harness.AgentAdapter.Codex"}}
  end

  test "a model-unavailable task is suppressed until its model becomes available" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-cron-model-unavailable", name: "cron-model-unavailable")
    assert :ok = ProjectRegistry.register(project)

    enable_project("cron-model-unavailable")
    Application.put_env(:harness, :notification_sinks, [CaptureSink])
    Application.put_env(:harness, :test_capture_pid, self())

    Application.put_env(:harness, :roadmap_ready, fn _p ->
      {:ok, ["130" |> task("codex") |> Map.put("model", "gpt-5.5")]}
    end)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      job = Ecto.Changeset.apply_action!(changeset, :insert)
      send(parent, {:inserted, job.args})
      {:ok, job}
    end)

    assert :ok = ModelAvailability.block_model("codex", "gpt-5.5", reason: "quota")

    log = capture_log(fn -> assert :ok = RoadmapPoller.perform(%Oban.Job{}) end)

    assert log =~ "task 130 dispatch suppressed"
    assert log =~ "adapter=Harness.AgentAdapter.Codex"
    assert log =~ "reason={:model_unavailable, :codex, \"gpt-5.5\""
    refute_received {:inserted, %{item_id: "130"}}

    assert_receive {:notify,
                    %Event{
                      type: :model_unavailable,
                      task_id: "130",
                      outcome: %{agent: "codex", model: "gpt-5.5"}
                    }}

    assert :ok = ModelAvailability.unblock_model("codex", "gpt-5.5")
    assert :ok = RoadmapPoller.perform(%Oban.Job{})

    assert_received {:inserted, %{item_id: "130", adapter_module: "Elixir.Harness.AgentAdapter.Codex"}}
  end

  test "master on dispatches only projects whose own autonomy flag is on" do
    parent = self()
    on_project = ProjectFixture.from_repo("/tmp/harness-cron-on", name: "cron-on", concurrency_cap: 10)
    off_project = ProjectFixture.from_repo("/tmp/harness-cron-off", name: "cron-off")
    assert :ok = ProjectRegistry.register(on_project)
    assert :ok = ProjectRegistry.register(off_project)

    assert :ok = Settings.set_master(true, "test")
    assert :ok = Settings.set_project("cron-on", true, "test")
    assert :ok = Settings.set_project("cron-off", false, "test")

    Application.put_env(:harness, :roadmap_ready, fn p ->
      send(parent, {:ready, p.name})
      {:ok, [task("51", nil)]}
    end)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      {:ok, Ecto.Changeset.apply_action!(changeset, :insert)}
    end)

    assert :ok = RoadmapPoller.perform(%Oban.Job{})

    # Effective autonomy = master AND project: the enabled sibling's roadmap is
    # read, the disabled one's is never touched.
    assert_received {:ready, "cron-on"}
    refute_received {:ready, "cron-off"}
  end

  describe "manual dispatch mode (Task 237)" do
    test "parks the single direct-dispatch task instead of enqueueing, and fires a witness event" do
      parent = self()
      project = ProjectFixture.from_repo("/tmp/harness-cron-manual1", name: "cron-manual1", concurrency_cap: 10)
      assert :ok = ProjectRegistry.register(project)

      enable_manual("cron-manual1")
      Application.put_env(:harness, :roadmap_ready, fn _p -> {:ok, [task("52", "codex")]} end)
      capture_inserts(parent)

      assert :ok = RoadmapPoller.perform(%Oban.Job{})

      # Parked, not enqueued.
      refute_received {:inserted, _args}

      assert [%PendingDispatch{task_id: "52", adapter: Codex, project_name: "cron-manual1"}] =
               PendingDispatch.list()

      assert_received {:notify, %Event{type: :dispatch_parked, task_id: "52", project: "cron-manual1"}}
    end

    test "parks the whole orchestrator-planned wave instead of enqueueing" do
      parent = self()
      project = ProjectFixture.from_repo("/tmp/harness-cron-manual2", name: "cron-manual2", concurrency_cap: 10)
      assert :ok = ProjectRegistry.register(project)

      enable_manual("cron-manual2")
      Application.put_env(:harness, :roadmap_ready, fn _p -> {:ok, [task("52", "codex"), task("53", "cursor")]} end)

      Application.put_env(:harness, :cron_orchestrator, fn _p, _ready ->
        {:ok,
         %Orchestrator{
           dispatch: [%{task_id: "52", adapter: "codex"}, %{task_id: "53", adapter: "cursor"}],
           skip: []
         }}
      end)

      capture_inserts(parent)

      assert :ok = RoadmapPoller.perform(%Oban.Job{})

      refute_received {:inserted, _args}
      assert PendingDispatch.list() |> Enum.map(& &1.task_id) |> Enum.sort() == ["52", "53"]
      assert_received {:notify, %Event{type: :dispatch_parked, task_id: "52"}}
      assert_received {:notify, %Event{type: :dispatch_parked, task_id: "53"}}
    end

    test "a re-tick does not duplicate a parked decision or re-notify" do
      project = ProjectFixture.from_repo("/tmp/harness-cron-manual-dedup", name: "cron-manual-dedup", concurrency_cap: 10)
      assert :ok = ProjectRegistry.register(project)

      enable_manual("cron-manual-dedup")
      Application.put_env(:harness, :roadmap_ready, fn _p -> {:ok, [task("52", "codex")]} end)

      assert :ok = RoadmapPoller.perform(%Oban.Job{})
      assert_received {:notify, %Event{type: :dispatch_parked, task_id: "52"}}

      # Second tick: the task is still pending (manual mode held it), so it must
      # not park a duplicate nor re-fire the witness event.
      assert :ok = RoadmapPoller.perform(%Oban.Job{})
      refute_received {:notify, _event}
      assert match?([_], PendingDispatch.list())
    end
  end

  test "reports the next tick from the configured schedule" do
    assert :ok = Settings.set_master(true, "test")

    assert {:ok, ~U[2026-05-27 01:00:00Z]} =
             RoadmapPoller.next_tick(~U[2026-05-27 00:15:00Z])
  end

  describe "task_agent/1" do
    test "routes every registry-backed assignee, not just the original three" do
      # The bug this guards: only claude/codex/cursor used to route; grok,
      # antigravity, pi silently fell back to :claude. All six resolve now.
      assert RoadmapPoller.task_agent(%{"assignee" => "codex", "model" => "claude-opus-4-7"}) == :codex
      assert RoadmapPoller.task_agent(%{"assignee" => "cursor"}) == :cursor
      assert RoadmapPoller.task_agent(%{"assignee" => "grok"}) == :grok
      assert RoadmapPoller.task_agent(%{"assignee" => "antigravity"}) == :antigravity
      assert RoadmapPoller.task_agent(%{"assignee" => "pi"}) == :pi
    end

    test "missing assignee is :no_assignee, never a claude default" do
      # The retired @default_agent=:claude silently burned Opus on unrouted work.
      # An unrouted task now carries no dispatch intent and is skipped, not defaulted.
      assert RoadmapPoller.task_agent(%{"model" => "codex", "markers" => ["csr"]}) == :no_assignee
      assert RoadmapPoller.task_agent(%{"assignee" => nil, "markers" => ["cx"]}) == :no_assignee
    end

    test "preserves human assignee for autonomous-dispatch skip" do
      assert RoadmapPoller.task_agent(%{"assignee" => "human"}) == :human
    end

    test "marks an assignee with no harness adapter unsupported, not a claude misroute" do
      # `droid` is renderable by rmap but has no harness adapter; it must be
      # skipped, never silently dispatched to the default agent.
      assert RoadmapPoller.task_agent(%{"assignee" => "droid"}) == {:unsupported_assignee, "droid"}

      assert RoadmapPoller.task_agent(%{"assignee" => "totally-unknown-xyz"}) ==
               {:unsupported_assignee, "totally-unknown-xyz"}
    end
  end

  defp cron_plugin?({Cron, _opts}), do: true
  defp cron_plugin?(_plugin), do: false

  # Reads the crontab out of whatever options the Cron plugin carries. Matching
  # the option list exactly (`{Cron, crontab: entries}`) silently degraded to []
  # the moment `Harness.Oban` added `:timezone`, turning a real assertion into a
  # vacuous one against an empty list.
  defp cron_crontab do
    HarnessOban.oban_opts()
    |> Keyword.get(:plugins, [])
    |> Enum.find_value([], fn
      {Cron, opts} when is_list(opts) -> Keyword.get(opts, :crontab, [])
      _ -> false
    end)
  end

  # A `rmap ready --dispatchable --fields id,assignee,markers` row.
  defp task(id, assignee), do: %{"id" => id, "assignee" => assignee, "markers" => []}

  # Turn on autonomy + manual dispatch mode for `name`, capturing park witness
  # events to the test process via the shared CaptureSink.
  defp enable_manual(name) do
    enable_project(name)
    Settings.set_dispatch_mode(name, :manual, "test")
    Application.put_env(:harness, :notification_sinks, [CaptureSink])
    Application.put_env(:harness, :test_capture_pid, self())
  end

  defp enable_project(name) do
    Settings.set_master(true, "test")
    Settings.set_project(name, true, "test")
  end

  defp capture_inserts(parent) do
    Application.put_env(:harness, :oban_insert, fn changeset ->
      job = Ecto.Changeset.apply_action!(changeset, :insert)
      send(parent, {:inserted, job.args})
      {:ok, job}
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:harness, key)
  defp restore_env(key, value), do: Application.put_env(:harness, key, value)
end
