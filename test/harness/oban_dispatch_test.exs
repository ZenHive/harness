defmodule Harness.ObanDispatchTest do
  use ExUnit.Case, async: false

  alias Harness.Batch
  alias Harness.Project
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.Roadmap.Item
  alias Harness.Run.Result
  alias Harness.Run.Worker

  setup do
    ProjectRegistry.reset()
    on_exit(fn -> Application.delete_env(:harness, :oban_insert) end)
    on_exit(fn -> Application.delete_env(:harness, :roadmap_ingest) end)
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

    assert {:snooze, seconds} =
             Worker.to_oban_result(%Result{
               run_id: "run-quota",
               task_id: "2",
               state: :failed,
               reason: {:agent_spawn_failed, "429 rate limit"}
             })

    assert is_integer(seconds) and seconds > 0

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
    assert_received {:start_run, "48", "worker-project", Harness.AgentAdapter.Claude, "oban-job-123"}
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

  test "worker maps performed terminal failures to cancel and quota failures to snooze" do
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

    quota_result = %Result{
      run_id: "run-quota",
      task_id: "49",
      state: :failed,
      reason: {:agent_spawn_failed, "429 rate limit"}
    }

    Application.put_env(:harness, :test_worker_result, quota_result)

    assert {:snooze, seconds} =
             Worker.perform(%{terminal_job | attempt: 2})

    assert is_integer(seconds) and seconds > 0
  end

  test "worker cancels loudly for invalid job arguments" do
    assert {:cancel, {:missing_arg, "item_id"}} =
             Worker.perform(%Oban.Job{args: %{"project_name" => "missing-item"}})

    project = ProjectFixture.from_repo("/tmp/harness-worker", name: "adapter-check")
    assert :ok = ProjectRegistry.register(project)

    assert {:cancel, {:unsupported_adapter, Harness.AgentAdapter.Grok}} =
             Worker.perform(%Oban.Job{
               args: %{
                 "project_name" => "adapter-check",
                 "item_id" => "1",
                 "adapter_module" => "Elixir.Harness.AgentAdapter.Grok"
               }
             })
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

  defp item(id, agent) do
    %Item{id: id, title: "Task #{id}", prompt: "do #{id}", agent: agent}
  end

  defp job(args) do
    %Oban.Job{id: 123, attempt: 1, args: args, meta: %{}}
  end

  describe "Harness.Oban pure surface (queue naming, limits, headroom guards — coverage lift)" do
    alias Harness.Oban

    test "queue_name public API and headroom guard (exercises enabled?/whereis/queued count paths)" do
      p1 = ProjectFixture.from_repo("/tmp/harness-oban-qn1", name: "demo", concurrency_cap: 4)
      p2 = ProjectFixture.from_repo("/tmp/harness-oban-qn2", name: "nocap")

      assert Oban.queue_name(p1) == "project_demo"
      assert Oban.queue_name("foo") == "project_foo"

      # Headroom guard: when ! (enabled? and whereis), returns true without hitting Ecto agg or limit.
      # This exercises the public queue_headroom? + private queues_enabled? + the else branch.
      assert Oban.queue_headroom?(p1) == true
      assert Oban.queue_headroom?(p2) == true
    end
  end
end
