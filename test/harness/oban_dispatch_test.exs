defmodule Harness.ObanDispatchTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Harness.AgentAdapter.Claude
  alias Harness.Batch
  alias Harness.Dashboard.RunFeed
  alias Harness.Dispatch
  alias Harness.Oban, as: HarnessOban
  alias Harness.Project
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.Roadmap.Item
  alias Harness.Run.Result
  alias Harness.Run.Worker

  setup do
    result_store = Application.get_env(:harness, :result_store)

    ProjectRegistry.reset()
    on_exit(fn -> Application.delete_env(:harness, :oban_insert) end)
    on_exit(fn -> Application.delete_env(:harness, :roadmap_ingest) end)
    on_exit(fn -> Application.put_env(:harness, :result_store, result_store) end)
    on_exit(fn -> Application.delete_env(:harness, :oban_run_job_lookup) end)
    on_exit(fn -> Application.delete_env(:harness, :run_starter) end)
    on_exit(fn -> Application.delete_env(:harness, :test_worker_result) end)
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
    assert {:ok, %{run_id: run_id}} = Dispatch.task("interactive", "2", "codex", true, true)

    assert_received {:inserted,
                     %Oban.Job{
                       args: %{
                         project_name: "interactive",
                         item_id: "2",
                         adapter_module: "Elixir.Harness.AgentAdapter.Codex",
                         run_id: ^run_id,
                         env: %{"ANTHROPIC_API_KEY" => false},
                         review_green: true
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
               reason: :passed
             })

    # Quota classification is disabled (quota_patterns: [], 2026-06-02): every
    # settled failure — including spawn failures that look like rate limits —
    # maps to :cancel, never :snooze. A settled verdict is never re-run by the
    # queue; quota judgment moves to the reviewer pair (Task 163).
    assert {:cancel, {:agent_spawn_failed, "429 rate limit"}} =
             Worker.to_oban_result(%Result{
               run_id: "run-quota",
               task_id: "2",
               state: :failed,
               reason: {:agent_spawn_failed, "429 rate limit"}
             })

    assert {:cancel, :verification_red} =
             Worker.to_oban_result(%Result{
               run_id: "run-red",
               task_id: "3",
               state: :failed,
               reason: :verification_red
             })
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
            {:harness_run, run_id, %Result{run_id: run_id, task_id: item.id, state: :done, reason: :passed}}
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
            {:harness_run, run_id, %Result{run_id: run_id, task_id: item.id, state: :done, reason: :passed}}
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
            {:harness_run, run_id, %Result{run_id: run_id, task_id: item.id, state: :done, reason: :passed}}
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
      send(parent, {:start_run_opts, run_id, Keyword.get(opts, :review_green)})
      subscriber = Keyword.fetch!(opts, :subscriber)

      pid =
        spawn(fn ->
          send(
            subscriber,
            {:harness_run, run_id, %Result{run_id: run_id, task_id: item.id, state: :done, reason: :passed}}
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
                 "run_id" => "run-interactive-156",
                 "review_green" => true
               }
             })

    assert_received {:start_run_opts, "run-interactive-156", true}
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
            {:harness_run, run_id, %Result{run_id: run_id, task_id: "48", state: :done, reason: :passed}}
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
            {:harness_run, run_id, %Result{run_id: run_id, task_id: item.id, state: :done, reason: :passed}}
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
    project = ProjectFixture.from_repo("/tmp/harness-worker", name: "worker-project")
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
        "project_name" => "worker-project",
        "item_id" => "49",
        "adapter_module" => "Elixir.Harness.AgentAdapter.Claude"
      })

    terminal_result = %Result{run_id: "run-red", task_id: "49", state: :failed, reason: :verification_red}
    Application.put_env(:harness, :test_worker_result, terminal_result)

    assert {:cancel, :verification_red} =
             Worker.perform(terminal_job)

    # Quota classification is disabled (quota_patterns: [], 2026-06-02): a
    # spawn failure that looks like a rate limit is a settled failure and
    # cancels — the queue never snooze-retries a settled run (Task 163).
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
    Application.put_env(:harness, :result_store, {Harness.ResultStore.File, root: root})

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
            {:harness_run, run_id, %Result{run_id: run_id, task_id: item.id, state: :done, reason: :passed}}
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

    assert is_integer(seconds) and seconds > 0
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
              {:harness_run, run_id, %Result{run_id: run_id, task_id: it.id, state: :done, reason: :passed}}
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
              {:harness_run, run_id, %Result{run_id: run_id, task_id: it.id, state: :done, reason: :passed}}
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

    test "terminal-failure run (verification_red after repairs) reverts to pending; transient does not" do
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

      # First: terminal red -> expect revert + {:cancel, _} from perform
      Application.put_env(:harness, :run_starter, fn %Item{} = it, _p, _a, opts ->
        run_id = "run-131-term"
        subscriber = Keyword.fetch!(opts, :subscriber)

        pid =
          spawn(fn ->
            send(
              subscriber,
              {:harness_run, run_id, %Result{run_id: run_id, task_id: it.id, state: :failed, reason: :verification_red}}
            )

            Process.sleep(50)
          end)

        {:ok, run_id, pid}
      end)

      assert {:cancel, :verification_red} =
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

      # Second: transient (e.g. worktree_failed) -> claim, snooze, NO revert
      Application.put_env(:harness, :run_starter, fn %Item{} = it, _p, _a, opts ->
        run_id = "run-131-trans"
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

      assert {:snooze, secs} =
               Worker.perform(%Oban.Job{
                 id: 134,
                 attempt: 2,
                 args: %{
                   "project_name" => "fail-proj",
                   "item_id" => "131f",
                   "adapter_module" => "Elixir.Harness.AgentAdapter.Claude"
                 }
               })

      assert is_integer(secs) and secs > 0
      assert_received :claimed_fail
      # No additional revert for the transient case
      refute_received {:reverted, _, _}
    end
  end

  defp item(id, agent, model \\ nil) do
    %Item{id: id, title: "Task #{id}", prompt: "do #{id}", agent: agent, model: model}
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
         notifier: Oban.Notifiers.Isolated,
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
        |> Worker.new(queue: queue, unique: unique_opts())
        |> Harness.Repo.insert()

      orphan
      |> Ecto.Changeset.change(state: "executing", attempted_at: DateTime.add(DateTime.utc_now(), -120, :second))
      |> Harness.Repo.update!()

      assert :ok = HarnessOban.rescue_orphaned_run_jobs()
      assert %{state: "available"} = Harness.Repo.reload!(orphan)

      assert {:ok, duplicate} =
               Oban.insert(HarnessOban, Worker.new(args, queue: queue, unique: unique_opts()))

      assert duplicate.id == orphan.id
      assert duplicate.conflict? == true
      assert Harness.Repo.aggregate(job_query(queue, args), :count, :id) == 1
    end

    @tag :integration
    test "boot rescue does not touch executing rows while a run is still live" do
      start_supervised!(Harness.Repo)
      :ok = Sandbox.checkout(Harness.Repo)

      project = ProjectFixture.from_repo("/tmp/harness-live-rescue", name: "live-rescue")
      queue = HarnessOban.queue_name(project)

      args = %{
        project_name: project.name,
        item_id: "158",
        adapter_module: Atom.to_string(Claude)
      }

      {:ok, job} =
        args
        |> Worker.new(queue: queue, unique: unique_opts())
        |> Harness.Repo.insert()

      job
      |> Ecto.Changeset.change(state: "executing", attempted_at: DateTime.add(DateTime.utc_now(), -120, :second))
      |> Harness.Repo.update!()

      {:ok, _} = Registry.register(Harness.Run.Registry, "live-run-158", nil)

      assert :ok = HarnessOban.rescue_orphaned_run_jobs()
      assert %{state: "executing"} = Harness.Repo.reload!(job)
    end
  end

  defp job_query(queue, args) do
    from(job in Oban.Job,
      where: job.queue == ^queue and job.worker == "Harness.Run.Worker" and job.args == ^stringify_keys(args)
    )
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp unique_opts do
    [
      keys: [:project_name, :item_id],
      states: [:available, :scheduled, :executing, :retryable],
      period: :infinity
    ]
  end
end
