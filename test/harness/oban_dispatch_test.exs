defmodule Harness.ObanDispatchTest do
  # async: false — app env, ProjectRegistry, Sandbox shared mode, and Oban singletons are global.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Harness.AgentAdapter.Claude
  alias Harness.Audit.Worker, as: AuditWorker
  alias Harness.Batch
  alias Harness.Dashboard.RunFeed
  alias Harness.Dispatch
  alias Harness.FakeAdapter
  alias Harness.GitFixture
  alias Harness.Lander.Worker, as: LanderWorker
  alias Harness.Oban, as: HarnessOban
  alias Harness.Project
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.ResultStore.Memory
  alias Harness.Roadmap.Item
  alias Harness.Run.Result
  alias Harness.Run.Supervisor, as: RunSupervisor
  alias Harness.Run.Worker
  alias Oban.Notifiers.Isolated
  alias Oban.Plugins.Lifeline

  @lifeline_rescue_after_ms to_timeout(second: 5)
  @lifeline_interval_ms 20
  @lifeline_wait_tries 50
  @lifeline_wait_delay_ms 20
  @stale_attempted_at_offset_ms @lifeline_rescue_after_ms + to_timeout(second: 1)
  @idempotency_run_timeout_ms 60_000
  @idempotency_wait_tries div(@idempotency_run_timeout_ms, @lifeline_wait_delay_ms)

  setup do
    result_store = Application.get_env(:harness, :result_store)

    ProjectRegistry.reset()
    on_exit(fn -> Application.delete_env(:harness, :oban_insert) end)
    on_exit(fn -> Application.delete_env(:harness, :roadmap_ingest) end)
    on_exit(fn -> Application.put_env(:harness, :result_store, result_store) end)
    on_exit(fn -> Application.delete_env(:harness, :oban_run_job_lookup) end)
    on_exit(fn -> Application.delete_env(:harness, :run_starter) end)
    on_exit(fn -> Application.delete_env(:harness, :test_worker_result) end)
    on_exit(fn -> Application.delete_env(:harness, :node_pressure_sampler) end)
    :ok
  end

  test "dispatch enqueues one worker job per item into the project's queue" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-dispatch", name: "alpha", concurrency_cap: 2)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      job = Ecto.Changeset.apply_action!(changeset, :insert)
      send(parent, {:inserted, job})
      {:ok, job}
    end)

    assert {:ok, jobs} =
             Batch.dispatch(project, [
               item("48", :claude),
               item("49", :codex)
             ])

    assert length(jobs) == 2

    assert_received {:inserted,
                     %Oban.Job{
                       args: %{
                         project_name: "alpha",
                         item_id: "48",
                         adapter_module: "Elixir.Harness.AgentAdapter.Claude"
                       },
                       meta: %{harness_stage: "dispatch"},
                       queue: "project_alpha",
                       worker: "Harness.Run.Worker"
                     }}

    assert_received {:inserted,
                     %Oban.Job{
                       args: %{
                         project_name: "alpha",
                         item_id: "49",
                         adapter_module: "Elixir.Harness.AgentAdapter.Codex"
                       },
                       queue: "project_alpha"
                     }}
  end

  test "dispatch/3 persists an :env override into each enqueued job's args" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-dispatch", name: "envbatch", concurrency_cap: 2)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      job = Ecto.Changeset.apply_action!(changeset, :insert)
      send(parent, {:inserted_args, job.args})
      {:ok, job}
    end)

    assert {:ok, [_job]} =
             Batch.dispatch(project, [item("48", :claude)], env: %{"ANTHROPIC_API_KEY" => false})

    assert_received {:inserted_args, %{env: %{"ANTHROPIC_API_KEY" => false}, item_id: "48"}}
  end

  test "dispatch/3 omits :env from job args when the override is empty" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-dispatch", name: "noenvbatch", concurrency_cap: 2)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      job = Ecto.Changeset.apply_action!(changeset, :insert)
      send(parent, {:inserted_args, job.args})
      {:ok, job}
    end)

    assert {:ok, [_job]} = Batch.dispatch(project, [item("48", :claude)], env: %{})

    assert_received {:inserted_args, args}
    refute Map.has_key?(args, :env)
  end

  test "dispatch-task enqueues a restart-resilient worker job with the returned run id" do
    parent = self()

    project =
      ProjectFixture.from_repo("/tmp/harness-dispatch-task",
        name: "interactive",
        roadmap_path: "test/fixtures/sample_roadmap"
      )

    Application.put_env(:harness, :oban_insert, fn changeset ->
      job = Ecto.Changeset.apply_action!(changeset, :insert)
      send(parent, {:inserted, job})
      {:ok, job}
    end)

    assert :ok = ProjectRegistry.register(project)

    # Task "2" pins no model; give codex a per-agent default so the dispatch
    # clears the model-required guard (a model-capable agent never falls through
    # to the CLI's ambient default).
    Harness.Config.put({:agent_model, :codex}, "gpt-5.5", "test")
    on_exit(fn -> Harness.Config.put({:agent_model, :codex}, "", "test") end)

    assert {:ok, %{run_id: run_id}} = Dispatch.task("interactive", "2", "codex", true)

    assert_received {:inserted,
                     %Oban.Job{
                       args: %{
                         project_name: "interactive",
                         item_id: "2",
                         adapter_module: "Elixir.Harness.AgentAdapter.Codex",
                         run_id: ^run_id,
                         env: %{"ANTHROPIC_API_KEY" => false}
                       },
                       meta: %{harness_stage: "dispatch"},
                       queue: "project_interactive",
                       worker: "Harness.Run.Worker"
                     }}
  end

  test "dispatch-status falls back to the persisted Oban worker job for a queued run id" do
    Application.put_env(:harness, :oban_run_job_lookup, fn
      "run-queued-156" ->
        {:ok,
         %Oban.Job{
           id: 156,
           state: "available",
           queue: "project_interactive",
           worker: "Harness.Run.Worker",
           args: %{
             "project_name" => "interactive",
             "item_id" => "2",
             "run_id" => "run-queued-156"
           }
         }}

      _other ->
        {:error, :not_found}
    end)

    assert {:ok, status} = Dispatch.status("run-queued-156")
    assert status.run_id == "run-queued-156"
    assert status.task_id == "2"
    assert status.project_name == "interactive"
    assert status.state == :dispatched
    assert status.reason == {:oban_job, "available"}
    assert status.oban_job_id == 156
    assert status.oban_state == "available"
    assert status.queue == "project_interactive"
  end

  test "registered project names resolve for dispatch" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-dispatch", name: "registered", concurrency_cap: 1)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      job = Ecto.Changeset.apply_action!(changeset, :insert)
      send(parent, {:inserted, job.queue})
      {:ok, job}
    end)

    assert :ok = ProjectRegistry.register(project)
    assert {:ok, [_job]} = Batch.dispatch("registered", [item("50", :cursor)])
    assert_received {:inserted, "project_registered"}
  end

  test "worker maps terminal run results onto Oban's return contract" do
    assert :ok =
             Worker.to_oban_result(%Result{
               run_id: "run-ok",
               task_id: "1",
               state: :done,
               reason: :approved
             })

    # Crash-only contract (Task 163): every settled failure — including spawn
    # failures that look like rate limits — maps to :cancel, never :snooze. A
    # settled verdict is never re-run by the queue; what a failure MEANS is the
    # reviewer's judgment inside the run, not the queue's.
    assert {:cancel, {:agent_spawn_failed, "429 rate limit"}} =
             Worker.to_oban_result(%Result{
               run_id: "run-quota",
               task_id: "2",
               state: :failed,
               reason: {:agent_spawn_failed, "429 rate limit"}
             })

    assert {:cancel, {:review_rejected, "not salvageable"}} =
             Worker.to_oban_result(%Result{
               run_id: "run-rejected",
               task_id: "3",
               state: :failed,
               reason: {:review_rejected, "not salvageable"}
             })
  end

  # Task 180: the run gen_statem is monitored (Process.monitor), never linked,
  # and drives its agents in async_nolink tasks — so a settling :failed run that
  # brutally kills its own linked helper (standing in for the MCP-transport /
  # agent-port :killed blast radius) cannot propagate an EXIT into the worker.
  # perform/1 returns {:cancel} (terminal, no re-dispatch) instead of dying with
  # "(EXIT from ...) killed" and being retried up to max_attempts.
  test "settled :failed run that brutally kills a linked helper still cancels the job (no retry storm)" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-teardown-kill", name: "teardown-kill")
    assert :ok = ProjectRegistry.register(project)

    on_exit(fn -> Application.delete_env(:harness, :roadmap_mark_pending) end)

    Application.put_env(:harness, :roadmap_ingest, fn _selector, _opts -> {:ok, item("42", :claude)} end)
    Application.put_env(:harness, :roadmap_mark_pending, fn _item, _project -> send(parent, :reverted) end)

    Application.put_env(:harness, :run_starter, fn %Item{} = item, _run_project, _adapter, opts ->
      send(parent, :start_run_called)
      run_id = "run-teardown-kill"
      subscriber = Keyword.fetch!(opts, :subscriber)

      pid =
        spawn(fn ->
          # The run's teardown blast radius: a helper linked to the run pid,
          # standing in for the MCP transport / agent port the run kills at settle.
          helper = spawn_link(fn -> Process.sleep(:infinity) end)

          send(
            subscriber,
            {:harness_run, run_id,
             %Result{run_id: run_id, task_id: item.id, state: :failed, reason: {:review_rejected, "teardown-kill"}}}
          )

          # Brutally kill the linked helper; :killed propagates to this run pid
          # too (no trap_exit), so the worker's monitor also sees {:DOWN, :killed}.
          Process.exit(helper, :kill)
        end)

      {:ok, run_id, pid}
    end)

    # The worker survives the blast radius and reports the settled verdict as a
    # terminal cancel — a linked-helper kill never reaches this (test) process.
    assert {:cancel, {:review_rejected, "teardown-kill"}} =
             Worker.perform(%Oban.Job{
               id: 118,
               attempt: 2,
               args: %{
                 "project_name" => "teardown-kill",
                 "item_id" => "42",
                 "adapter_module" => "Elixir.Harness.AgentAdapter.Claude",
                 "run_id" => "run-teardown-kill"
               }
             })

    # Settled failure reverts the task to pending exactly once — no second attempt.
    assert_received :start_run_called
    assert_received :reverted
    refute_received :start_run_called
  end

  test "worker performs a job through project lookup, roadmap ingestion, and run startup" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-worker", name: "worker-project")
    assert :ok = ProjectRegistry.register(project)

    Application.put_env(:harness, :roadmap_ingest, fn selector, opts ->
      send(parent, {:ingest, selector, opts[:project].name, opts[:agent]})
      {:ok, item("48", :claude)}
    end)

    Application.put_env(:harness, :run_starter, fn %Item{} = item, run_project, adapter, opts ->
      send(parent, {:start_run, item.id, run_project.name, adapter, Keyword.fetch!(opts, :batch_id)})
      run_id = "run-worker-ok"
      subscriber = Keyword.fetch!(opts, :subscriber)

      pid =
        spawn(fn ->
          send(
            subscriber,
            {:harness_run, run_id, %Result{run_id: run_id, task_id: item.id, state: :done, reason: :approved}}
          )

          Process.sleep(100)
        end)

      {:ok, run_id, pid}
    end)

    assert :ok =
             Worker.perform(%Oban.Job{
               id: 123,
               attempt: 1,
               args: %{
                 "project_name" => "worker-project",
                 "item_id" => "48",
                 "adapter_module" => "Elixir.Harness.AgentAdapter.Claude"
               }
             })

    assert_received {:ingest, {:id, "48"}, "worker-project", :claude}
    assert_received {:start_run, "48", "worker-project", Claude, "oban-job-123"}
  end

  test "worker threads a persisted :env override from job args into start_run" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-worker", name: "env-project")
    assert :ok = ProjectRegistry.register(project)

    Application.put_env(:harness, :roadmap_ingest, fn _selector, _opts ->
      {:ok, item("48", :claude)}
    end)

    Application.put_env(:harness, :run_starter, fn %Item{} = item, _run_project, _adapter, opts ->
      send(parent, {:start_env, Keyword.get(opts, :env)})
      run_id = "run-env-ok"
      subscriber = Keyword.fetch!(opts, :subscriber)

      pid =
        spawn(fn ->
          send(
            subscriber,
            {:harness_run, run_id, %Result{run_id: run_id, task_id: item.id, state: :done, reason: :approved}}
          )

          Process.sleep(100)
        end)

      {:ok, run_id, pid}
    end)

    assert :ok =
             Worker.perform(%Oban.Job{
               id: 124,
               attempt: 1,
               args: %{
                 "project_name" => "env-project",
                 "item_id" => "48",
                 "adapter_module" => "Elixir.Harness.AgentAdapter.Claude",
                 "env" => %{"ANTHROPIC_API_KEY" => false}
               }
             })

    # The scrub the dispatch layer persisted into the job args reaches start_run.
    assert_received {:start_env, %{"ANTHROPIC_API_KEY" => false}}
  end

  test "worker threads the ingested item's model into start_run as requested_model" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-worker", name: "model-project")
    assert :ok = ProjectRegistry.register(project)

    Application.put_env(:harness, :roadmap_ingest, fn _selector, _opts ->
      {:ok, item("48", :codex, "gpt-5.4")}
    end)

    Application.put_env(:harness, :run_starter, fn %Item{} = item, _run_project, _adapter, opts ->
      send(parent, {:start_requested_model, Keyword.get(opts, :requested_model), item.id})
      run_id = "run-model-ok"
      subscriber = Keyword.fetch!(opts, :subscriber)

      pid =
        spawn(fn ->
          send(
            subscriber,
            {:harness_run, run_id, %Result{run_id: run_id, task_id: item.id, state: :done, reason: :approved}}
          )

          Process.sleep(100)
        end)

      {:ok, run_id, pid}
    end)

    assert :ok =
             Worker.perform(%Oban.Job{
               id: 126,
               attempt: 1,
               args: %{
                 "project_name" => "model-project",
                 "item_id" => "48",
                 "adapter_module" => "Elixir.Harness.AgentAdapter.Codex"
               }
             })

    assert_received {:start_requested_model, "gpt-5.4", "48"}
  end

  test "worker starts runs with the persisted run id from job args" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-worker", name: "run-id-project")
    assert :ok = ProjectRegistry.register(project)

    Application.put_env(:harness, :roadmap_ingest, fn _selector, _opts ->
      {:ok, item("156", :codex)}
    end)

    Application.put_env(:harness, :run_starter, fn %Item{} = item, _run_project, _adapter, opts ->
      run_id = Keyword.fetch!(opts, :run_id)
      send(parent, {:start_run_opts, run_id})
      subscriber = Keyword.fetch!(opts, :subscriber)

      pid =
        spawn(fn ->
          send(
            subscriber,
            {:harness_run, run_id, %Result{run_id: run_id, task_id: item.id, state: :done, reason: :approved}}
          )

          Process.sleep(50)
        end)

      {:ok, run_id, pid}
    end)

    assert :ok =
             Worker.perform(%Oban.Job{
               id: 156,
               attempt: 1,
               args: %{
                 "project_name" => "run-id-project",
                 "item_id" => "156",
                 "adapter_module" => "Elixir.Harness.AgentAdapter.Codex",
                 "run_id" => "run-interactive-156"
               }
             })

    assert_received {:start_run_opts, "run-interactive-156"}
  end

  test "worker omits requested_model when the ingested item carries none" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-worker", name: "nomodel-project")
    assert :ok = ProjectRegistry.register(project)

    Application.put_env(:harness, :roadmap_ingest, fn _selector, _opts ->
      {:ok, item("48", :claude)}
    end)

    Application.put_env(:harness, :run_starter, fn %Item{} = _item, _run_project, _adapter, opts ->
      send(parent, {:start_requested_model?, Keyword.has_key?(opts, :requested_model)})
      run_id = "run-nomodel-ok"
      subscriber = Keyword.fetch!(opts, :subscriber)

      pid =
        spawn(fn ->
          send(
            subscriber,
            {:harness_run, run_id, %Result{run_id: run_id, task_id: "48", state: :done, reason: :approved}}
          )

          Process.sleep(100)
        end)

      {:ok, run_id, pid}
    end)

    assert :ok =
             Worker.perform(%Oban.Job{
               id: 127,
               attempt: 1,
               args: %{
                 "project_name" => "nomodel-project",
                 "item_id" => "48",
                 "adapter_module" => "Elixir.Harness.AgentAdapter.Claude"
               }
             })

    assert_received {:start_requested_model?, false}
  end

  test "worker omits :env when job args carry no override" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-worker", name: "noenv-project")
    assert :ok = ProjectRegistry.register(project)

    Application.put_env(:harness, :roadmap_ingest, fn _selector, _opts ->
      {:ok, item("48", :claude)}
    end)

    Application.put_env(:harness, :run_starter, fn %Item{} = item, _run_project, _adapter, opts ->
      send(parent, {:start_env_present?, Keyword.has_key?(opts, :env)})
      run_id = "run-noenv-ok"
      subscriber = Keyword.fetch!(opts, :subscriber)

      pid =
        spawn(fn ->
          send(
            subscriber,
            {:harness_run, run_id, %Result{run_id: run_id, task_id: item.id, state: :done, reason: :approved}}
          )

          Process.sleep(100)
        end)

      {:ok, run_id, pid}
    end)

    assert :ok =
             Worker.perform(%Oban.Job{
               id: 125,
               attempt: 1,
               args: %{
                 "project_name" => "noenv-project",
                 "item_id" => "48",
                 "adapter_module" => "Elixir.Harness.AgentAdapter.Claude"
               }
             })

    assert_received {:start_env_present?, false}
  end

  test "worker maps performed terminal failures to cancel" do
    project = ProjectFixture.from_repo("/tmp/harness-terminal-worker", name: "terminal-worker-project")
    assert :ok = ProjectRegistry.register(project)

    Application.put_env(:harness, :roadmap_ingest, fn _selector, _opts ->
      {:ok, item("49", :claude)}
    end)

    Application.put_env(:harness, :run_starter, fn item, _project, _adapter, opts ->
      result = Application.fetch_env!(:harness, :test_worker_result)
      run_id = result.run_id
      subscriber = Keyword.fetch!(opts, :subscriber)

      pid =
        spawn(fn ->
          send(subscriber, {:harness_run, run_id, %{result | task_id: item.id}})
          Process.sleep(100)
        end)

      {:ok, run_id, pid}
    end)

    terminal_job =
      job(%{
        "project_name" => "terminal-worker-project",
        "item_id" => "49",
        "adapter_module" => "Elixir.Harness.AgentAdapter.Claude"
      })

    terminal_result = %Result{
      run_id: "run-rejected",
      task_id: "49",
      state: :failed,
      reason: {:review_rejected, "not salvageable"}
    }

    Application.put_env(:harness, :test_worker_result, terminal_result)

    assert {:cancel, {:review_rejected, "not salvageable"}} =
             Worker.perform(terminal_job)

    # Crash-only contract (Task 163): a spawn failure that looks like a rate
    # limit is a settled failure and cancels — the queue never snooze-retries
    # a settled run.
    spawn_failed_result = %Result{
      run_id: "run-quota",
      task_id: "49",
      state: :failed,
      reason: {:agent_spawn_failed, "429 rate limit"}
    }

    Application.put_env(:harness, :test_worker_result, spawn_failed_result)

    assert {:cancel, {:agent_spawn_failed, "429 rate limit"}} =
             Worker.perform(%{terminal_job | attempt: 2})
  end

  test "worker records and broadcasts a monitored run process crash" do
    root = Path.join(System.tmp_dir!(), "harness-worker-crash-#{System.unique_integer([:positive])}")
    Application.put_env(:harness, :result_store, {Memory, root: root})

    project = ProjectFixture.from_repo("/tmp/harness-worker", name: "crash-project")
    assert :ok = ProjectRegistry.register(project)
    :ok = RunFeed.subscribe()

    Application.put_env(:harness, :roadmap_ingest, fn _selector, _opts ->
      {:ok, item("134", :claude)}
    end)

    Application.put_env(:harness, :run_starter, fn %Item{} = _item, _project, _adapter, _opts ->
      {:ok, "run-crashed-worker", spawn(fn -> exit(:boom) end)}
    end)

    assert {:cancel, {:run_crashed, :boom}} =
             Worker.perform(%Oban.Job{
               id: 134,
               attempt: 1,
               args: %{
                 "project_name" => "crash-project",
                 "item_id" => "134",
                 "adapter_module" => "Elixir.Harness.AgentAdapter.Claude"
               }
             })

    assert {:ok, [record]} = ResultStore.list_run_records(run_id: "run-crashed-worker")
    assert record.batch_id == "oban-job-134"
    assert record.task_id == "134"
    assert record.project_name == "crash-project"
    assert record.agent == :claude
    assert record.adapter == Claude
    assert record.state == :failed
    assert record.reason == {:run_crashed, :boom}

    assert_receive {:harness_run_settled, status}
    assert status.run_id == "run-crashed-worker"
    assert status.task_id == "134"
    assert status.project_name == "crash-project"
    assert status.agent == :claude
    assert status.state == :failed
    assert status.reason == {:run_crashed, :boom}
  end

  test "worker cancels a duplicate re-attempt while the run is in flight, off the retry/cleanup path" do
    project = ProjectFixture.from_repo("/tmp/harness-worker", name: "dup-project")
    assert :ok = ProjectRegistry.register(project)

    Application.put_env(:harness, :roadmap_ingest, fn _selector, _opts -> {:ok, item("180", :claude)} end)
    Application.put_env(:harness, :roadmap_mark_in_progress, fn _item, _project -> :ok end)
    on_exit(fn -> Application.delete_env(:harness, :roadmap_mark_in_progress) end)

    # A prior attempt's run for this run_id is still alive, so start_run collides
    # on the {:via, Registry, ...} registration: DynamicSupervisor.start_child
    # returns {:error, {:already_started, pid}} (the 2026-06-03 job-118 case).
    live = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(live, :kill) end)

    Application.put_env(:harness, :run_starter, fn %Item{} = _item, _project, _adapter, _opts ->
      {:error, {:already_started, live}}
    end)

    # Cancelled terminally as a duplicate — NOT snoozed onto the mechanical-retry
    # path, which would run cleanup_for_run and destroy the LIVE run's worktree.
    assert {:cancel, {:duplicate_run_in_flight, ^live}} =
             Worker.perform(%Oban.Job{
               id: 180,
               attempt: 1,
               args: %{
                 "project_name" => "dup-project",
                 "item_id" => "180",
                 "adapter_module" => "Elixir.Harness.AgentAdapter.Claude",
                 "run_id" => "run-dup-180"
               }
             })
  end

  test "worker cancels loudly for invalid job arguments" do
    assert {:cancel, {:missing_arg, "item_id"}} =
             Worker.perform(%Oban.Job{args: %{"project_name" => "missing-item"}})

    project = ProjectFixture.from_repo("/tmp/harness-worker", name: "adapter-check")
    assert :ok = ProjectRegistry.register(project)

    # A loaded module that is not a harness adapter cancels loudly. (Every real
    # adapter — including Grok/Antigravity/Pi — is accepted; see the routing test
    # below.)
    assert {:cancel, {:unsupported_adapter, Project}} =
             Worker.perform(%Oban.Job{
               args: %{
                 "project_name" => "adapter-check",
                 "item_id" => "1",
                 "adapter_module" => "Elixir.Harness.Project"
               }
             })
  end

  test "worker accepts every registered adapter, not just claude/codex/cursor" do
    parent = self()
    project = ProjectFixture.from_repo("/tmp/harness-worker", name: "grok-project")
    assert :ok = ProjectRegistry.register(project)

    Application.put_env(:harness, :roadmap_ingest, fn _selector, opts ->
      send(parent, {:ingest_agent, Keyword.fetch!(opts, :agent)})
      {:ok, item("9", :grok)}
    end)

    Application.put_env(:harness, :run_starter, fn %Item{} = item, _run_project, adapter, opts ->
      send(parent, {:start_adapter, adapter})
      run_id = "run-grok-ok"
      subscriber = Keyword.fetch!(opts, :subscriber)

      pid =
        spawn(fn ->
          send(
            subscriber,
            {:harness_run, run_id, %Result{run_id: run_id, task_id: item.id, state: :done, reason: :approved}}
          )

          Process.sleep(100)
        end)

      {:ok, run_id, pid}
    end)

    assert :ok =
             Worker.perform(%Oban.Job{
               id: 909,
               attempt: 1,
               args: %{
                 "project_name" => "grok-project",
                 "item_id" => "9",
                 "adapter_module" => "Elixir.Harness.AgentAdapter.Grok"
               }
             })

    # The fix: a Grok adapter is no longer cancelled at the agent gate — it
    # resolves to the :grok render agent and reaches start_run.
    assert_received {:ingest_agent, :grok}
    assert_received {:start_adapter, Harness.AgentAdapter.Grok}
  end

  # Review fix #12: a persisted job referencing a not-yet-registered project is
  # a transient setup failure (boot race / pending registration), not bad data.
  # It must snooze-and-retry so a BEAM restart can recover the work, rather than
  # being permanently discarded with {:cancel, _}.
  test "worker snoozes a transient setup failure instead of cancelling" do
    # ProjectRegistry.reset/0 ran in setup — "ghost" is unregistered, so
    # ProjectRegistry.lookup/1 returns {:error, {:unknown_project, _}}.
    assert {:snooze, seconds} =
             Worker.perform(%Oban.Job{
               id: 7,
               attempt: 1,
               args: %{
                 "project_name" => "ghost",
                 "item_id" => "1",
                 "adapter_module" => "Elixir.Harness.AgentAdapter.Claude"
               }
             })

    assert seconds > 0
  end

  # Task 202: the node-pressure admission gate is the aggregate companion to the
  # per-run memory watchdog. Over the high-water mark, a NEW run snoozes (the job
  # is HELD for re-dispatch, not discarded) before any gen_statem is spawned.
  test "worker snoozes NEW admission when host memory pressure is over the high-water mark" do
    put_run_env(mem_highwater_kb: 1_000, mem_pressure_snooze: 9)
    Application.put_env(:harness, :node_pressure_sampler, fn -> 2_000 end)

    # The gate fires before start_run — a run must never be admitted under pressure.
    Application.put_env(:harness, :run_starter, fn _item, _project, _adapter, _opts ->
      flunk("run admitted while over the node-pressure high-water mark")
    end)

    assert {:snooze, 9} =
             Worker.perform(%Oban.Job{
               id: 202,
               attempt: 1,
               args: %{
                 "project_name" => "pressure-project",
                 "item_id" => "202",
                 "adapter_module" => "Elixir.Harness.AgentAdapter.Claude"
               }
             })
  end

  test "worker admits the run when host memory pressure is under the high-water mark" do
    parent = self()
    put_run_env(mem_highwater_kb: 100_000)
    Application.put_env(:harness, :node_pressure_sampler, fn -> 50_000 end)

    project = ProjectFixture.from_repo("/tmp/harness-under-pressure", name: "under-pressure-project")
    assert :ok = ProjectRegistry.register(project)

    Application.put_env(:harness, :roadmap_ingest, fn _selector, _opts -> {:ok, item("202", :claude)} end)

    Application.put_env(:harness, :run_starter, fn %Item{} = item, _run_project, _adapter, opts ->
      send(parent, :admitted)
      run_id = "run-under-pressure"
      subscriber = Keyword.fetch!(opts, :subscriber)

      pid =
        spawn(fn ->
          send(
            subscriber,
            {:harness_run, run_id, %Result{run_id: run_id, task_id: item.id, state: :done, reason: :approved}}
          )

          Process.sleep(100)
        end)

      {:ok, run_id, pid}
    end)

    assert :ok =
             Worker.perform(%Oban.Job{
               id: 203,
               attempt: 1,
               args: %{
                 "project_name" => "under-pressure-project",
                 "item_id" => "202",
                 "adapter_module" => "Elixir.Harness.AgentAdapter.Claude"
               }
             })

    assert_received :admitted
  end

  test "mechanical retries hit a hard ceiling and cancel with :mechanical_retry_exhausted" do
    # Snoozes do not consume Oban's max_attempts, so without the ceiling a
    # permanently broken environment (unregistered project, dead rmap) would
    # snooze forever. At the ceiling the job cancels loudly instead.
    assert {:cancel, {:mechanical_retry_exhausted, {:unknown_project, "ghost"}}} =
             Worker.perform(%Oban.Job{
               id: 7,
               attempt: 5,
               args: %{
                 "project_name" => "ghost",
                 "item_id" => "1",
                 "adapter_module" => "Elixir.Harness.AgentAdapter.Claude"
               }
             })
  end

  test "a mechanical start failure cleans the prior attempt's run branch before snoozing (Task 168 regression)" do
    repo = GitFixture.init_repo()
    project = ProjectFixture.from_repo(repo, name: "collision-project")
    assert :ok = ProjectRegistry.register(project)

    run_id = "run-collision-regression"

    # Simulate the prior attempt's leftovers: the run branch already exists, so
    # a re-attempt's `git worktree add -b harness/<run_id>` would collide and
    # fail every retry (the 2026-06-02 branch-collision cascade).
    GitFixture.git!(repo, ["branch", "harness/#{run_id}"])

    Application.put_env(:harness, :roadmap_ingest, fn _selector, _opts -> {:ok, item("168", :claude)} end)

    Application.put_env(:harness, :run_starter, fn _item, _project, _adapter, _opts ->
      {:error, :port_spawn_failed}
    end)

    assert {:snooze, seconds} =
             Worker.perform(%Oban.Job{
               id: 168,
               attempt: 2,
               args: %{
                 "project_name" => "collision-project",
                 "item_id" => "168",
                 "adapter_module" => "Elixir.Harness.AgentAdapter.Claude",
                 "run_id" => run_id
               }
             })

    assert seconds > 0

    # The leftover branch is gone — the next attempt's worktree add starts clean.
    assert repo |> GitFixture.git!(["branch", "--list", "harness/#{run_id}"]) |> String.trim() == ""
  end

  test "worker retry reuses a stale run branch instead of cancelling on worktree creation" do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    root = Path.join(System.tmp_dir!(), "harness-worker-retry-#{System.unique_integer([:positive])}")
    run_id = "run-retry-existing-branch"
    branch = "harness/#{run_id}"
    project = ProjectFixture.from_repo(repo, name: "retry-branch-project")

    GitFixture.git!(repo, ["branch", branch])
    Application.put_env(:harness, :result_store, {Memory, root: root})
    assert :ok = ProjectRegistry.register(project)

    Application.put_env(:harness, :roadmap_ingest, fn _selector, _opts -> {:ok, item("195", :claude)} end)

    Application.put_env(:harness, :run_starter, fn %Item{} = item, run_project, _adapter, opts ->
      run_opts = [
        base_dir: base,
        adapter_opts: [command: :write],
        reviewer: FakeAdapter,
        reviewer_adapter_opts: [command: {:review, "approve"}],
        total_timeout: 30_000,
        idle_timeout: 10_000,
        lifetime_timeout: 30_000,
        terminal_linger: 100
      ]

      RunSupervisor.start_run(item, run_project, FakeAdapter, opts ++ run_opts)
    end)

    assert :ok =
             Worker.perform(%Oban.Job{
               id: 195,
               attempt: 2,
               args: %{
                 "project_name" => project.name,
                 "item_id" => "195",
                 "adapter_module" => "Elixir.Harness.AgentAdapter.Claude",
                 "run_id" => run_id
               }
             })

    assert GitFixture.git!(repo, ["ls-tree", "-r", "--name-only", branch]) =~ "agent_output.txt"
  end

  describe "Task 131: claim on run start + revert only on terminal failure (via seams)" do
    setup do
      on_exit(fn ->
        Application.delete_env(:harness, :roadmap_mark_in_progress)
        Application.delete_env(:harness, :roadmap_mark_pending)
      end)

      :ok
    end

    test "claims in_progress on run start (best-effort writeback before start_run)" do
      parent = self()
      project = ProjectFixture.from_repo("/tmp/harness-131-claim", name: "claim-proj")
      assert :ok = ProjectRegistry.register(project)

      Application.put_env(:harness, :roadmap_ingest, fn _sel, _opts -> {:ok, item("131c", :claude)} end)

      Application.put_env(:harness, :roadmap_mark_in_progress, fn %Item{id: id}, %Project{name: name} ->
        send(parent, {:claimed, id, name})
        :ok
      end)

      Application.put_env(:harness, :run_starter, fn %Item{} = it, _p, _a, opts ->
        run_id = "run-131-claim"
        subscriber = Keyword.fetch!(opts, :subscriber)

        pid =
          spawn(fn ->
            send(
              subscriber,
              {:harness_run, run_id, %Result{run_id: run_id, task_id: it.id, state: :done, reason: :approved}}
            )

            Process.sleep(50)
          end)

        {:ok, run_id, pid}
      end)

      assert :ok =
               Worker.perform(%Oban.Job{
                 id: 131,
                 attempt: 1,
                 args: %{
                   "project_name" => "claim-proj",
                   "item_id" => "131c",
                   "adapter_module" => "Elixir.Harness.AgentAdapter.Claude"
                 }
               })

      assert_received {:claimed, "131c", "claim-proj"}
      # Green passed: no revert
      refute_received {:reverted, _}
    end

    test "green-unlanded run leaves task in_progress (no revert call)" do
      parent = self()
      project = ProjectFixture.from_repo("/tmp/harness-131-green", name: "green-proj")
      assert :ok = ProjectRegistry.register(project)

      Application.put_env(:harness, :roadmap_ingest, fn _sel, _opts -> {:ok, item("131g", :claude)} end)

      Application.put_env(:harness, :roadmap_mark_in_progress, fn _item, _proj ->
        send(parent, :claimed_green)
        :ok
      end)

      Application.put_env(:harness, :roadmap_mark_pending, fn _item, _proj ->
        send(parent, :reverted_green)
        :ok
      end)

      Application.put_env(:harness, :run_starter, fn %Item{} = it, _p, _a, opts ->
        run_id = "run-131-green"
        subscriber = Keyword.fetch!(opts, :subscriber)

        pid =
          spawn(fn ->
            send(
              subscriber,
              {:harness_run, run_id, %Result{run_id: run_id, task_id: it.id, state: :done, reason: :approved}}
            )

            Process.sleep(50)
          end)

        {:ok, run_id, pid}
      end)

      assert :ok =
               Worker.perform(%Oban.Job{
                 id: 132,
                 attempt: 1,
                 args: %{
                   "project_name" => "green-proj",
                   "item_id" => "131g",
                   "adapter_module" => "Elixir.Harness.AgentAdapter.Claude"
                 }
               })

      assert_received :claimed_green
      refute_received :reverted_green
    end

    test "any settled failure reverts the task to pending and cancels the job (crash-only contract)" do
      parent = self()
      project = ProjectFixture.from_repo("/tmp/harness-131-fail", name: "fail-proj")
      assert :ok = ProjectRegistry.register(project)

      Application.put_env(:harness, :roadmap_ingest, fn _sel, _opts -> {:ok, item("131f", :claude)} end)

      Application.put_env(:harness, :roadmap_mark_in_progress, fn _item, _proj ->
        send(parent, :claimed_fail)
        :ok
      end)

      Application.put_env(:harness, :roadmap_mark_pending, fn %Item{id: id}, %Project{name: n} ->
        send(parent, {:reverted, id, n})
        :ok
      end)

      # A reviewer rejection is a settled failure -> revert + {:cancel, _} from perform
      Application.put_env(:harness, :run_starter, fn %Item{} = it, _p, _a, opts ->
        run_id = "run-131-term"
        subscriber = Keyword.fetch!(opts, :subscriber)

        pid =
          spawn(fn ->
            send(
              subscriber,
              {:harness_run, run_id,
               %Result{run_id: run_id, task_id: it.id, state: :failed, reason: {:review_rejected, "rejected"}}}
            )

            Process.sleep(50)
          end)

        {:ok, run_id, pid}
      end)

      assert {:cancel, {:review_rejected, "rejected"}} =
               Worker.perform(%Oban.Job{
                 id: 133,
                 attempt: 1,
                 args: %{
                   "project_name" => "fail-proj",
                   "item_id" => "131f",
                   "adapter_module" => "Elixir.Harness.AgentAdapter.Claude"
                 }
               })

      assert_received :claimed_fail
      assert_received {:reverted, "131f", "fail-proj"}

      # Task 163 crash-only contract: a run that SETTLED on a mechanical-looking
      # reason (worktree_failed) is still a settled failure — the queue cancels
      # and reverts; the next cron tick re-dispatches it as a FRESH run. Only
      # setup failures (the {:error, _} path before a run settles) snooze.
      Application.put_env(:harness, :run_starter, fn %Item{} = it, _p, _a, opts ->
        run_id = "run-131-settled-mechanical"
        subscriber = Keyword.fetch!(opts, :subscriber)

        pid =
          spawn(fn ->
            send(
              subscriber,
              {:harness_run, run_id,
               %Result{run_id: run_id, task_id: it.id, state: :failed, reason: {:worktree_failed, :boom}}}
            )

            Process.sleep(50)
          end)

        {:ok, run_id, pid}
      end)

      assert {:cancel, {:worktree_failed, :boom}} =
               Worker.perform(%Oban.Job{
                 id: 134,
                 attempt: 2,
                 args: %{
                   "project_name" => "fail-proj",
                   "item_id" => "131f",
                   "adapter_module" => "Elixir.Harness.AgentAdapter.Claude"
                 }
               })

      assert_received :claimed_fail
      assert_received {:reverted, "131f", "fail-proj"}
    end
  end

  defp item(id, agent, model \\ nil) do
    %Item{id: id, title: "Task #{id}", prompt: "do #{id}", agent: agent, model: model}
  end

  # Merge keys into the :harness :run config (runtime.exs seeds it with
  # max_hold_timeout) and restore the original on exit, so node-pressure gate
  # tests can set mem_highwater_kb / mem_pressure_snooze without clobbering it.
  defp put_run_env(extra) do
    original = Application.get_env(:harness, :run, [])
    Application.put_env(:harness, :run, Keyword.merge(original, extra))
    on_exit(fn -> Application.put_env(:harness, :run, original) end)
  end

  defp job(args) do
    %Oban.Job{id: 123, attempt: 1, args: args, meta: %{}}
  end

  describe "Harness.Oban pure surface (queue naming, limits, headroom guards — coverage lift)" do
    test "queue_name public API and headroom guard (exercises enabled?/whereis/queued count paths)" do
      p1 = ProjectFixture.from_repo("/tmp/harness-oban-qn1", name: "demo", concurrency_cap: 4)
      p2 = ProjectFixture.from_repo("/tmp/harness-oban-qn2", name: "nocap")

      assert HarnessOban.queue_name(p1) == "project_demo"
      assert HarnessOban.queue_name("foo") == "project_foo"

      # Headroom guard: when ! (enabled? and whereis), returns true without hitting Ecto agg or limit.
      # This exercises the public queue_headroom? + private queues_enabled? + the else branch.
      assert HarnessOban.queue_headroom?(p1) == true
      assert HarnessOban.queue_headroom?(p2) == true
    end

    test "oban_opts/0 includes Lifeline with a thirty minute rescue window" do
      plugins = HarnessOban.oban_opts()[:plugins]

      assert {Lifeline, opts} =
               Enum.find(plugins, &match?({Lifeline, _opts}, &1))

      assert opts[:rescue_after] == to_timeout(minute: 30)
    end

    test "unfinished_run_job? detects non-terminal run jobs for a project task" do
      start_supervised!(Harness.Repo)
      :ok = Sandbox.checkout(Harness.Repo)

      project = ProjectFixture.from_repo("/tmp/harness-unfinished-run-job", name: "unfinished-run-job")
      queue = HarnessOban.queue_name(project)

      args = %{
        project_name: project.name,
        item_id: "237",
        adapter_module: Atom.to_string(Claude)
      }

      {:ok, job} = Harness.Repo.insert(Worker.new(args, queue: queue))

      assert HarnessOban.unfinished_run_job?(project, "237")
      refute HarnessOban.unfinished_run_job?(project, "other")

      job
      |> Ecto.Changeset.change(state: "completed")
      |> Harness.Repo.update!()

      refute HarnessOban.unfinished_run_job?(project, "237")
    end
  end

  describe "run worker in-flight uniqueness" do
    test "second dispatch while the first job is executing returns the live run id without a duplicate run" do
      start_supervised!(Harness.Repo)
      :ok = Sandbox.checkout(Harness.Repo)
      Sandbox.mode(Harness.Repo, {:shared, self()})

      start_dispatch_oban!()

      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()
      gate = Path.join(System.tmp_dir!(), "harness-dispatch-idempotent-#{System.unique_integer([:positive])}")
      project = ProjectFixture.from_repo(repo, name: "dispatch-idempotent", concurrency_cap: 10)
      item = item("286", :claude)

      on_exit(fn -> File.rm(gate) end)
      Application.put_env(:harness, :roadmap_mark_in_progress, fn _item, _project -> :ok end)
      Application.put_env(:harness, :roadmap_ingest, fn _selector, _opts -> {:ok, item} end)

      Application.put_env(:harness, :run_starter, fn %Item{} = run_item, run_project, _adapter, opts ->
        RunSupervisor.start_run(
          run_item,
          run_project,
          FakeAdapter,
          opts ++
            [
              base_dir: base,
              adapter_opts: [command: {:write_then_wait_for_file, gate}],
              reviewer: FakeAdapter,
              reviewer_adapter_opts: [command: {:review, "approve"}],
              total_timeout: @idempotency_run_timeout_ms,
              idle_timeout: @idempotency_run_timeout_ms,
              lifetime_timeout: @idempotency_run_timeout_ms,
              terminal_linger: 100
            ]
        )
      end)

      assert :ok = ProjectRegistry.register(project)
      assert {:ok, first_run_id, first_job} = Worker.enqueue(project, item, Claude)

      assert_eventually_lifeline(
        fn ->
          assert [%Oban.Job{state: "executing"}] = run_jobs(project, item.id)
          assert [^first_run_id] = RunSupervisor.list_runs()
        end,
        @idempotency_wait_tries
      )

      assert {:ok, second_run_id, second_job} = Worker.enqueue(project, item, Claude)

      assert second_run_id == first_run_id
      assert second_job.id == first_job.id
      assert second_job.conflict? == true
      assert [%Oban.Job{}] = run_jobs(project, item.id)
      assert [^first_run_id] = RunSupervisor.list_runs()

      File.write!(gate, "go")

      assert_eventually_lifeline(
        fn ->
          assert [%Oban.Job{state: "completed"}] = run_jobs(project, item.id)
          assert [] = RunSupervisor.list_runs()
        end,
        @idempotency_wait_tries
      )
    end

    test "a terminal prior job does not block a fresh dispatch for the same task" do
      start_supervised!(Harness.Repo)
      :ok = Sandbox.checkout(Harness.Repo)

      start_dispatch_oban!()

      project = ProjectFixture.from_repo("/tmp/harness-terminal-redo", name: "terminal-redo")
      item = item("286", :claude)

      assert {:ok, first_run_id, first_job} = Worker.enqueue(project, item, Claude)

      first_job
      |> Ecto.Changeset.change(state: "completed")
      |> Harness.Repo.update!()

      assert {:ok, second_run_id, second_job} = Worker.enqueue(project, item, Claude)

      refute second_run_id == first_run_id
      refute second_job.id == first_job.id
      assert second_job.conflict? == false
      assert length(run_jobs(project, item.id)) == 2
    end
  end

  describe "lifeline rescue for landing and audit jobs" do
    @tag :integration
    test "old executing landing and audit jobs become available while fresh executing jobs stay put" do
      previous_oban = Application.get_env(:harness, Oban)

      Application.put_env(:harness, Oban,
        repo: Harness.Repo,
        queues: false,
        plugins: false,
        notifier: Isolated,
        peer: Oban.Peers.Isolated
      )

      on_exit(fn -> Application.put_env(:harness, Oban, previous_oban) end)

      start_supervised!(Harness.Repo)
      :ok = Sandbox.checkout(Harness.Repo)
      Sandbox.mode(Harness.Repo, {:shared, self()})

      project = ProjectFixture.from_repo("/tmp/harness-lifeline", name: "lifeline")

      old_landing =
        insert_executing_job!(
          LanderWorker.new(landing_args(project), queue: HarnessOban.landing_queue_name(project)),
          stale_attempted_at()
        )

      old_audit =
        insert_executing_job!(
          AuditWorker.new(audit_args(project), unique: AuditWorker.unique_opts()),
          stale_attempted_at()
        )

      fresh_audit =
        insert_executing_job!(
          AuditWorker.new(audit_args(%{project | name: "lifeline-fresh"}), unique: AuditWorker.unique_opts()),
          DateTime.utc_now()
        )

      oban_opts = HarnessOban.oban_opts()
      lifeline_plugins = oban_opts |> Keyword.get(:plugins, []) |> lifeline_test_plugins()

      start_supervised!(
        {Oban,
         Keyword.merge(oban_opts,
           queues: false,
           plugins: lifeline_plugins,
           stage_interval: :infinity
         )}
      )

      assert_eventually_lifeline(fn ->
        assert %{state: "available"} = Harness.Repo.reload!(old_landing)
        assert %{state: "available"} = Harness.Repo.reload!(old_audit)
      end)

      assert %{state: "executing"} = Harness.Repo.reload!(fresh_audit)
    end
  end

  describe "orphaned executing run jobs" do
    @tag :integration
    test "boot rescue makes an orphaned executing Run.Worker row runnable without inserting a duplicate" do
      start_supervised!(Harness.Repo)
      :ok = Sandbox.checkout(Harness.Repo)
      Sandbox.mode(Harness.Repo, {:shared, self()})

      start_supervised!(
        {Oban,
         name: HarnessOban,
         repo: Harness.Repo,
         notifier: Isolated,
         queues: false,
         plugins: false,
         stage_interval: :infinity}
      )

      project = ProjectFixture.from_repo("/tmp/harness-orphan-rescue", name: "orphan-rescue")
      queue = HarnessOban.queue_name(project)

      args = %{
        project_name: project.name,
        item_id: "157",
        adapter_module: Atom.to_string(Claude)
      }

      {:ok, orphan} =
        args
        |> Worker.new(queue: queue, unique: Worker.unique_opts())
        |> Harness.Repo.insert()

      orphan
      |> Ecto.Changeset.change(state: "executing", attempted_at: DateTime.add(DateTime.utc_now(), -120, :second))
      |> Harness.Repo.update!()

      assert :ok = HarnessOban.rescue_orphaned_run_jobs()
      assert %{state: "available"} = Harness.Repo.reload!(orphan)

      assert {:ok, duplicate} =
               Oban.insert(HarnessOban, Worker.new(args, queue: queue, unique: Worker.unique_opts()))

      assert duplicate.id == orphan.id
      assert duplicate.conflict? == true
      assert Harness.Repo.aggregate(job_query(queue, args), :count, :id) == 1
    end

    @tag :integration
    test "boot rescue does not touch the executing row whose run is still live" do
      start_supervised!(Harness.Repo)
      :ok = Sandbox.checkout(Harness.Repo)

      project = ProjectFixture.from_repo("/tmp/harness-live-rescue", name: "live-rescue")
      queue = HarnessOban.queue_name(project)

      args = %{
        project_name: project.name,
        item_id: "158",
        adapter_module: Atom.to_string(Claude),
        run_id: "live-run-158"
      }

      {:ok, job} =
        args
        |> Worker.new(queue: queue, unique: Worker.unique_opts())
        |> Harness.Repo.insert()

      job
      |> Ecto.Changeset.change(state: "executing", attempted_at: DateTime.add(DateTime.utc_now(), -120, :second))
      |> Harness.Repo.update!()

      {:ok, _} = Registry.register(Harness.Run.Registry, "live-run-158", nil)

      assert :ok = HarnessOban.rescue_orphaned_run_jobs()
      assert %{state: "executing"} = Harness.Repo.reload!(job)
    end

    @tag :integration
    test "boot rescue recovers an orphaned executing row even while an unrelated run is live" do
      start_supervised!(Harness.Repo)
      :ok = Sandbox.checkout(Harness.Repo)

      project = ProjectFixture.from_repo("/tmp/harness-mixed-rescue", name: "mixed-rescue")
      queue = HarnessOban.queue_name(project)

      live_args = %{
        project_name: project.name,
        item_id: "159",
        adapter_module: Atom.to_string(Claude),
        run_id: "live-run-159"
      }

      orphan_args = %{
        project_name: project.name,
        item_id: "160",
        adapter_module: Atom.to_string(Claude),
        run_id: "orphan-run-160"
      }

      {:ok, live_job} = live_args |> Worker.new(queue: queue, unique: Worker.unique_opts()) |> Harness.Repo.insert()
      {:ok, orphan_job} = orphan_args |> Worker.new(queue: queue, unique: Worker.unique_opts()) |> Harness.Repo.insert()

      for job <- [live_job, orphan_job] do
        job
        |> Ecto.Changeset.change(state: "executing", attempted_at: DateTime.add(DateTime.utc_now(), -120, :second))
        |> Harness.Repo.update!()
      end

      # Only the run behind live_job is registered; orphan-run-160 crashed a prior boot.
      {:ok, _} = Registry.register(Harness.Run.Registry, "live-run-159", nil)

      assert :ok = HarnessOban.rescue_orphaned_run_jobs()

      assert %{state: "executing"} = Harness.Repo.reload!(live_job)
      assert %{state: "available"} = Harness.Repo.reload!(orphan_job)
    end
  end

  defp job_query(queue, args) do
    from(job in Oban.Job,
      where: job.queue == ^queue and job.worker == "Harness.Run.Worker" and job.args == ^stringify_keys(args)
    )
  end

  defp run_jobs(project, item_id) do
    queue = HarnessOban.queue_name(project)

    Harness.Repo.all(
      from(job in Oban.Job,
        where:
          job.queue == ^queue and job.worker == "Harness.Run.Worker" and
            fragment("?->>? = ?", job.args, "project_name", ^project.name) and
            fragment("?->>? = ?", job.args, "item_id", ^item_id),
        order_by: [asc: job.id]
      )
    )
  end

  defp start_dispatch_oban! do
    previous_oban = Application.get_env(:harness, Oban)

    Application.put_env(:harness, Oban,
      repo: Harness.Repo,
      queues: false,
      plugins: false,
      notifier: Isolated,
      peer: Oban.Peers.Isolated
    )

    on_exit(fn -> Application.put_env(:harness, Oban, previous_oban) end)

    start_supervised!({Oban, Keyword.put(Application.get_env(:harness, Oban), :name, HarnessOban)})
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp landing_args(project) do
    %{
      "project_name" => project.name,
      "run_id" => "lifeline-run",
      "task_id" => "209",
      "agent" => "codex",
      "branch" => "harness/lifeline-run",
      "land_attempt" => 1
    }
  end

  defp audit_args(project), do: %{"project_name" => project.name, "base_sha" => "abc123"}

  defp insert_executing_job!(changeset, attempted_at) do
    {:ok, job} = Harness.Repo.insert(changeset)

    job
    |> Ecto.Changeset.change(state: "executing", attempt: 1, attempted_at: attempted_at)
    |> Harness.Repo.update!()
  end

  defp stale_attempted_at do
    DateTime.add(DateTime.utc_now(), -@stale_attempted_at_offset_ms, :millisecond)
  end

  defp lifeline_test_plugins(plugins) do
    Enum.flat_map(List.wrap(plugins), fn
      {Lifeline, opts} ->
        [{Lifeline, Keyword.merge(opts, interval: @lifeline_interval_ms, rescue_after: @lifeline_rescue_after_ms)}]

      Lifeline ->
        [{Lifeline, interval: @lifeline_interval_ms, rescue_after: @lifeline_rescue_after_ms}]

      _other ->
        []
    end)
  end

  defp assert_eventually_lifeline(fun, tries \\ @lifeline_wait_tries)
  defp assert_eventually_lifeline(fun, 1), do: fun.()

  defp assert_eventually_lifeline(fun, tries) when tries > 1 do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(@lifeline_wait_delay_ms)
      assert_eventually_lifeline(fun, tries - 1)
  end
end
