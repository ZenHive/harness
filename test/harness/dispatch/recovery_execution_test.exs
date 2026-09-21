defmodule Harness.Dispatch.RecoveryExecutionTest do
  use Harness.DataCase, async: false

  alias Harness.AgentAdapter.Codex
  alias Harness.AgentRegistry
  alias Harness.Cron.Orchestrator
  alias Harness.Cron.PendingDispatch
  alias Harness.Cron.RoadmapPoller
  alias Harness.Cron.Settings
  alias Harness.Dispatch
  alias Harness.Dispatch.Attempts
  alias Harness.Dispatch.Decision
  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.ResultStore.Postgres
  alias Harness.Roadmap
  alias Harness.Run.LogRecord
  alias Harness.Run.Status
  alias Harness.Run.Worker
  alias Harness.Test.IdentityFakeAdapter

  setup {Harness.Test.AgentRegistryIsolation, :isolate}

  defmodule WitnessAdapter do
    @moduledoc false
    use Harness.AgentAdapter

    defdelegate capabilities(), to: IdentityFakeAdapter
    defdelegate rule_channel(), to: IdentityFakeAdapter

    def build_command(invocation) do
      send(Application.fetch_env!(:harness, :task435_owner), {:invocation, invocation.log_tag, invocation.prompt})
      IdentityFakeAdapter.build_command(invocation)
    end
  end

  @moduletag :integration

  setup do
    keys = [
      :result_store,
      :roadmap_ready,
      :roadmap_ingest,
      :run_starter,
      :roadmap_mark_in_progress,
      :roadmap_mark_pending,
      :cron_orchestrator,
      :agent_model,
      :repo_enabled,
      :notification_sinks,
      :task435_owner
    ]

    prior = Map.new(keys, &{&1, Application.fetch_env(:harness, &1)})

    on_exit(fn ->
      Enum.each(prior, fn
        {key, {:ok, value}} -> Application.put_env(:harness, key, value)
        {key, :error} -> Application.delete_env(:harness, key)
      end)

      PendingDispatch.reset()
      ProjectRegistry.reset()
    end)

    Application.put_env(:harness, :task435_owner, self())
    AgentRegistry.reset()
    ProjectRegistry.reset()
    PendingDispatch.reset()
    Application.put_env(:harness, :result_store, {Postgres, repo: Harness.Repo})
    Application.put_env(:harness, :repo_enabled, true)
    Application.put_env(:harness, :agent_model, codex: "gpt-6-astra")
    Application.put_env(:harness, :notification_sinks, [])

    start_supervised!(
      {Oban,
       name: Harness.Oban,
       repo: Harness.Repo,
       queues: false,
       plugins: false,
       testing: :manual,
       notifier: Oban.Notifiers.Isolated,
       peer: Oban.Peers.Isolated}
    )

    %{repo: repo} = GitFixture.init_with_origin()

    project =
      ProjectFixture.from_repo(repo,
        name: "recovery-#{System.unique_integer([:positive])}",
        target_branch: "main",
        concurrency_cap: 1
      )

    :ok = ProjectRegistry.register(project)
    File.mkdir_p!(Path.join(repo, "roadmap"))

    File.write!(Path.join(repo, "roadmap/tasks.toml"), """
    schema_version = 2
    project = "recovery"
    default_branch = "main"
    vision = "Recovery regression"
    [phases.1]
    name = "Test"
    order = 1
    status = "in_progress"
    [bundles.test]
    description = "Test"
    order = 1
    phase = 1
    [[task]]
    id = "435"
    bundle = "test"
    phase = 1
    status = "pending"
    title = "Retain delivery"
    body = "Repair the result"
    acceptance_criteria = ["The retained delivery passes review"]
    assignee = "codex"
    model = "gpt-6-astra"
    scores = { d = 3, b = 7, u = 7 }
    created_at = "2026-09-18"
    """)

    GitFixture.git!(repo, ["add", "roadmap/tasks.toml"])
    GitFixture.git!(repo, ["commit", "-m", "task contract"])
    GitFixture.git!(repo, ["push", "origin", "main"])

    assert {:ok, [task]} =
             Roadmap.ready(
               project: project,
               fields: ~w(id title body assignee model acceptance_criteria files_to_modify out_of_scope)
             )

    assert {:ok, item} = Roadmap.ingest({:id, "435"}, project: project, agent: :codex)
    owner = self()
    Application.put_env(:harness, :roadmap_ingest, fn _, _ -> {:ok, item} end)
    Application.put_env(:harness, :roadmap_ready, fn _ -> {:ok, [task]} end)
    Application.put_env(:harness, :roadmap_mark_in_progress, fn _, _ -> :ok end)

    Application.put_env(:harness, :roadmap_mark_pending, fn _, _ ->
      send(owner, :pending)
      :ok
    end)

    Settings.set_master(true, "test")
    Settings.set_project(project.name, true, "test")
    Settings.set_dispatch_mode(project.name, :auto, "test")
    %{repo: repo, project: project, item: item, task: task}
  end

  test "reject to pending to cron resumes the committed SHA and exact report through Oban", ctx do
    starter(self(), "reject")
    assert {:ok, old_id, _job} = Worker.enqueue(ctx.project, ctx.item, Codex)
    assert %{cancelled: 1} = drain(ctx.project)
    assert_received :pending
    assert_received {:started, _, _}
    assert {:ok, prior} = ResultStore.fetch_run_record(old_id)
    assert prior.verdict == :reject, inspect(prior.reason)
    sha = ctx.repo |> GitFixture.git!(["rev-parse", "harness/" <> old_id]) |> String.trim()

    owner = self()

    Application.put_env(:harness, :cron_orchestrator, fn _, [task] ->
      send(owner, {:history, task["attempts"]})

      {:ok,
       %Orchestrator{
         dispatch: [
           %{
             task_id: ctx.item.id,
             adapter: "codex",
             model: "gpt-6-astra",
             action: "resume",
             source_run_id: old_id,
             reason: "Retain the delivery and repair reviewer findings"
           }
         ],
         skip: []
       }}
    end)

    starter(self(), "approve")
    assert :ok = RoadmapPoller.perform(%Oban.Job{})
    assert :ok = RoadmapPoller.perform(%Oban.Job{})
    assert_received {:history, [%{"review_report" => report, "git" => %{"selected_sha" => ^sha}}]}
    assert report == prior.review_report
    assert %{success: 1} = drain(ctx.project)
    assert_received {:started, resumed, opts}
    assert resumed.prompt =~ prior.review_report
    assert_received {:invocation, "435", _first_prompt}
    assert_received {:invocation, "435", actual_prompt}
    assert actual_prompt =~ prior.review_report
    assert opts[:base_ref] == sha
    assert opts[:env]["OPENAI_API_KEY"] == false
    assert opts[:requested_model] == "gpt-6-astra"
    new_id = opts[:run_id]
    assert {:ok, ""} = Harness.Git.run(["merge-base", "--is-ancestor", sha, "harness/" <> new_id], ctx.repo)
    assert {:ok, record} = ResultStore.fetch_run_record(new_id)
    assert record.dispatch_decision["source_run_id"] == old_id
    assert record.dispatch_decision["selected_sha"] == sha
    assert record.dispatch_decision["reason"] == "Retain the delivery and repair reviewer findings"
    assert {:ok, status} = Dispatch.status(new_id)
    assert status.dispatch_decision == record.dispatch_decision
    assert {:ok, verdict} = Dispatch.verdict_detail(new_id)
    assert verdict.dispatch_decision == record.dispatch_decision
    assert Status.from_log_record(record).dispatch_decision == record.dispatch_decision
  end

  test "an explicitly justified fresh build uses origin rather than the retained delivery", ctx do
    {old_id, _resume} = retained(ctx)
    assert {:ok, [task]} = Attempts.attach(ctx.project, [ctx.task])

    assert {:ok, decision} =
             Decision.capture(ctx.project, task, %{
               action: "fresh",
               adapter: "codex",
               model: "gpt-6-astra",
               reason: "Replace the incompatible implementation"
             })

    starter(self(), "approve")

    assert {:ok, id, _job} =
             Worker.enqueue(ctx.project, ctx.item, Codex, dispatch_decision: decision, requested_model: "gpt-6-astra")

    assert %{success: 1} = drain(ctx.project)
    assert_received {:started, item, opts}
    origin = ctx.repo |> GitFixture.git!(["rev-parse", "origin/main"]) |> String.trim()
    assert opts[:base_ref] == origin
    refute item.prompt =~ "Exact reviewer report"

    assert {:error, {:git_failed, _, 1, _}} =
             Harness.Git.run(["merge-base", "--is-ancestor", "harness/" <> old_id, "harness/" <> id], ctx.repo)

    assert {:ok, record} = ResultStore.fetch_run_record(id)
    assert record.dispatch_decision["action"] == "fresh"
    assert record.dispatch_decision["selected_sha"] == origin
  end

  test "a failed attempt without delivered changes does not make origin look already landed", ctx do
    {old_id, _resume} = retained(ctx)
    assert {:ok, record} = ResultStore.fetch_run_record(old_id)
    :ok = ResultStore.record_run(%{record | agent_diff_size: 0, reviewer_diff_size: 0})
    GitFixture.git!(ctx.repo, ["update-ref", "refs/heads/harness/" <> old_id, "origin/main"])
    assert {:ok, [task]} = Attempts.attach(ctx.project, [ctx.task])

    assert {:ok, decision} =
             Decision.capture(ctx.project, task, %{
               action: "fresh",
               adapter: "codex",
               model: "gpt-6-astra",
               reason: "No prior delivery to retain"
             })

    assert {:ok, _item, _opts} = Decision.prepare(ctx.project, ctx.item, Codex, decision)
  end

  test "parked recovery preserves routing and rejects a moved branch at worker start", ctx do
    {old_id, decision} = retained(ctx)
    Settings.set_dispatch_mode(ctx.project.name, :manual, "test")

    Application.put_env(:harness, :cron_orchestrator, fn _, _ ->
      {:ok,
       %Orchestrator{
         dispatch: [
           %{
             task_id: ctx.item.id,
             adapter: "codex",
             model: "gpt-6-astra",
             action: "resume",
             source_run_id: old_id,
             reason: "Keep useful work"
           }
         ],
         skip: []
       }}
    end)

    assert :ok = RoadmapPoller.perform(%Oban.Job{})
    assert [parked] = PendingDispatch.list()
    assert parked.opts[:dispatch_decision]["selected_sha"] == decision["selected_sha"]
    assert {:ok, %{run_id: id}} = PendingDispatch.approve(parked.id)
    assert {:error, :not_found} = PendingDispatch.approve(parked.id)
    GitFixture.git!(ctx.repo, ["update-ref", "refs/heads/harness/" <> old_id, "origin/main"])
    owner = self()

    Application.put_env(:harness, :run_starter, fn _, _, _, _ ->
      send(owner, :unexpected_start)
      {:error, :unexpected}
    end)

    assert %{cancelled: 1} = drain(ctx.project)
    refute_received :unexpected_start
    job = Harness.Repo.one!(from job in Oban.Job, where: fragment("?->>? = ?", job.args, "run_id", ^id))
    assert inspect(job.errors) =~ "stale_dispatch_decision"
    assert {:ok, status} = Dispatch.status(id)
    assert status.state == :failed
    assert status.dispatch_decision["source_run_id"] == old_id
    assert {:stale_dispatch_decision, _detail} = status.reason
  end

  test "fresh uses origin; identity, missing branches, landed work and coalesced sources fail visibly", ctx do
    {old_id, decision} = retained(ctx)

    assert {:ok, _, opts} =
             Decision.prepare(ctx.project, ctx.item, Codex, %{decision | "action" => "fresh", "source_run_id" => nil})

    assert opts[:base_ref] == String.trim(GitFixture.git!(ctx.repo, ["rev-parse", "origin/main"]))

    assert {:error, {:stale_dispatch_decision, :task_content_changed}} =
             Decision.prepare(ctx.project, %{ctx.item | fingerprint: "changed"}, Codex, decision)

    assert {:error, {:stale_dispatch_decision, :project_changed}} =
             Decision.prepare(%{ctx.project | name: "other"}, ctx.item, Codex, decision)

    assert {:error, {:stale_dispatch_decision, :task_changed}} =
             Decision.prepare(ctx.project, %{ctx.item | id: "other"}, Codex, decision)

    assert {:ok, record} = ResultStore.fetch_run_record(old_id)
    :ok = ResultStore.record_run(%{record | task_ids: [ctx.item.id, "436"]})
    assert {:error, _} = Decision.prepare(ctx.project, ctx.item, Codex, decision)
    :ok = ResultStore.record_run(%{record | task_ids: [ctx.item.id]})
    GitFixture.git!(ctx.repo, ["push", "origin", "harness/#{old_id}:main"])

    assert {:error, {:stale_dispatch_decision, :work_already_landed}} =
             Decision.prepare(ctx.project, ctx.item, Codex, decision)

    GitFixture.git!(ctx.repo, ["branch", "-D", "harness/" <> old_id])
    assert {:error, _} = Decision.prepare(ctx.project, ctx.item, Codex, decision)
  end

  test "public recovery APIs enqueue, and rereview never invokes an implementer", ctx do
    {old_id, _decision} = retained(ctx)
    starter(self(), "approve")
    assert {:ok, %{run_id: new_id, rereviewed_from: ^old_id}} = Dispatch.rereview(old_id)
    refute_received {:invocation, _, _}
    assert %{success: 1} = drain(ctx.project)
    assert_received {:invocation, "435-review", _}
    refute_received {:invocation, "435", _}
    assert {:ok, record} = ResultStore.fetch_run_record(new_id)
    assert record.dispatch_decision["action"] == "rereview"
    assert {:ok, %{run_id: resumed_id, resumed_from: ^old_id}} = Dispatch.resume_failed(old_id)
    assert resumed_id != new_id
    assert %{success: 1} = drain(ctx.project)
    assert_received {:invocation, "435", prompt}
    assert prompt =~ "Exact reviewer report\nsecond line"
  end

  test "shutdown records recover through public APIs and the dispatch job keeps the shutdown cause", ctx do
    owner = self()
    admission = __MODULE__.ShutdownAdmission

    sup =
      start_supervised!(
        {Harness.Run.Supervisor, name: __MODULE__.ShutdownSupervisor, admission: admission, runs: __MODULE__.ShutdownRuns}
      )

    Application.put_env(:harness, :run_starter, fn item, project, _adapter, opts ->
      {:ok, id, pid} =
        Harness.Run.Supervisor.start_run(
          item,
          project,
          WitnessAdapter,
          Keyword.merge(opts,
            admission: admission,
            requested_model: nil,
            adapter_opts: [command: :write],
            reviewer: Harness.Test.ShutdownAdapter,
            reviewer_adapter_opts: [owner: owner],
            terminal_linger: 0
          )
        )

      send(owner, {:shutdown_run, id, pid})
      {:ok, id, pid}
    end)

    assert {:ok, old_id, job} = Worker.enqueue(ctx.project, ctx.item, Codex)
    draining = Task.async(fn -> drain(ctx.project) end)
    assert_receive {:shutdown_run, ^old_id, pid}, 10_000
    assert_receive {:invoking, driver, cwd}, 10_000
    :erlang.trace(pid, true, [:receive, {:tracer, self()}])
    send(driver, :spawn)
    assert_receive {:trace, ^pid, :receive, {:reviewer_handle, _handle}}, 5_000
    sha = String.trim(GitFixture.git!(cwd, ["rev-parse", "HEAD"]))
    assert :ok = Supervisor.stop(sup)
    assert %{cancelled: 1} = Task.await(draining, 10_000)
    assert {:ok, record} = ResultStore.fetch_run_record(old_id)
    assert record.reason == {:shutdown, :reviewing}
    persisted_job = Harness.Repo.get!(Oban.Job, job.id)
    assert persisted_job.state == "cancelled"
    assert inspect(persisted_job.errors) =~ "shutdown"
    refute inspect(persisted_job.errors) =~ ":cancelled"
    assert_received {:invocation, "435", _}

    starter(owner, "approve")
    assert {:ok, %{run_id: reviewed}} = Dispatch.rereview(old_id)
    assert %{success: 1} = drain(ctx.project)
    assert_received {:invocation, "435-review", _}
    refute_received {:invocation, "435", _}
    assert {:ok, reviewed_record} = ResultStore.fetch_run_record(reviewed)
    assert reviewed_record.dispatch_decision["selected_sha"] == sha

    assert {:ok, %{run_id: resumed}} = Dispatch.resume_failed(old_id)
    assert %{success: 1} = drain(ctx.project)
    assert_received {:invocation, "435", prompt}
    assert prompt =~ "shutdown"
    assert {:ok, resumed_record} = ResultStore.fetch_run_record(resumed)
    assert resumed_record.dispatch_decision["selected_sha"] == sha

    GitFixture.git!(ctx.repo, ["worktree", "remove", "--force", cwd])
    GitFixture.git!(ctx.repo, ["branch", "-D", "harness/" <> old_id])
    assert {:error, :source_unavailable_or_landed} = Dispatch.rereview(old_id)
    assert {:error, :source_unavailable_or_landed} = Dispatch.resume_failed(old_id)
  end

  test "legacy membership and stale first-attempt jobs cannot narrow or erase prior work", ctx do
    {old_id, decision} = retained(ctx)
    assert {:ok, record} = ResultStore.fetch_run_record(old_id)

    assert {:ok, _job} =
             Harness.Oban.insert(
               Worker.new(
                 %{run_id: old_id, project_name: ctx.project.name, item_id: ctx.item.id, item_ids: [ctx.item.id, "436"]},
                 queue: "legacy_membership",
                 state: "cancelled"
               )
             )

    :ok = ResultStore.record_run(%{record | task_ids: []})
    assert {:ok, legacy} = ResultStore.fetch_run_record(old_id)
    assert Attempts.membership(legacy) == [ctx.item.id, "436"]

    assert {:error, {:stale_dispatch_decision, :source_changed_or_landed}} =
             Decision.prepare(ctx.project, ctx.item, Codex, decision)

    assert {:ok, [secondary]} = Attempts.attach(ctx.project, [%{"id" => "436"}])
    assert [%{"run_id" => ^old_id}] = secondary["attempts"]

    assert {:cancel, {:stale_dispatch_decision, :first_attempt_changed}} =
             Worker.perform(%Oban.Job{
               id: 999,
               attempt: 1,
               args: %{
                 "project_name" => ctx.project.name,
                 "item_id" => ctx.item.id,
                 "adapter_module" => to_string(Codex),
                 "cron_first_attempt" => true,
                 "task_fingerprint" => ctx.item.fingerprint
               }
             })
  end

  test "a first-attempt job is revalidated then started from the current target", ctx do
    starter(self(), "approve")

    assert {:ok, _id, _job} =
             Worker.enqueue(ctx.project, ctx.item, Codex,
               cron_first_attempt: true,
               task_fingerprint: ctx.item.fingerprint,
               requested_model: "gpt-6-astra"
             )

    assert %{success: 1} = drain(ctx.project)
    assert_received {:started, item, opts}
    refute opts[:review_only?]
    assert opts[:base_ref] in [nil, "HEAD"]
    refute item.prompt =~ "Prior attempt failed"
    refute item.prompt =~ "Exact reviewer report"

    assert {:cancel, {:stale_dispatch_decision, :first_attempt_changed}} =
             Worker.perform(%Oban.Job{
               id: 1001,
               attempt: 1,
               args: %{
                 "project_name" => ctx.project.name,
                 "item_id" => ctx.item.id,
                 "adapter_module" => to_string(Codex),
                 "run_id" => "stale-first",
                 "cron_first_attempt" => true,
                 "task_fingerprint" => "changed-content"
               }
             })

    assert {:ok, stale} = ResultStore.fetch_run_record("stale-first")
    assert stale.state == :failed
    assert {:stale_dispatch_decision, :first_attempt_changed} = stale.reason
  end

  test "a historical singleton never accepts an implicit fresh plan or failed history read", ctx do
    {_old_id, _decision} = retained(ctx)
    owner = self()

    Application.put_env(:harness, :cron_orchestrator, fn _, [task] ->
      send(owner, {:planned_history, task["attempts"]})
      {:ok, %Orchestrator{dispatch: [%{task_id: ctx.item.id, adapter: "codex"}], skip: []}}
    end)

    assert :ok = RoadmapPoller.perform(%Oban.Job{})
    assert_received {:planned_history, [_attempt]}
    assert [] = Harness.Repo.all(from job in Oban.Job, where: job.queue == ^Harness.Oban.queue_name(ctx.project))
    Application.put_env(:harness, :result_store, false)
    assert :ok = RoadmapPoller.perform(%Oban.Job{})
    refute_received {:planned_history, _}
    assert [] = Harness.Repo.all(from job in Oban.Job, where: job.queue == ^Harness.Oban.queue_name(ctx.project))
  end

  test "new attempts and disabled routing invalidate a queued decision", ctx do
    {old_id, decision} = retained(ctx)
    assert :ok = AgentRegistry.mark_unavailable(Codex, :quota)

    assert {:error, {:stale_dispatch_decision, :routing_unavailable}} =
             Decision.prepare(ctx.project, ctx.item, Codex, decision)

    assert :ok = AgentRegistry.mark_available(Codex)
    assert {:ok, record} = ResultStore.fetch_run_record(old_id)
    :ok = ResultStore.record_run(%{record | run_id: "another-attempt"})

    assert {:error, {:stale_dispatch_decision, :attempt_history_changed}} =
             Decision.prepare(ctx.project, ctx.item, Codex, decision)
  end

  test "concurrent recovery enqueue is project/task idempotent", ctx do
    {_old_id, decision} = retained(ctx)

    results =
      1..4
      |> Task.async_stream(
        fn _ ->
          Worker.enqueue(ctx.project, ctx.item, Codex, dispatch_decision: decision, requested_model: "gpt-6-astra")
        end,
        ordered: false
      )
      |> Enum.to_list()

    ids = Enum.map(results, fn {:ok, {:ok, id, _job}} -> id end)
    assert [_id] = Enum.uniq(ids)
    assert [_job] = Harness.Repo.all(from job in Oban.Job, where: job.queue == ^Harness.Oban.queue_name(ctx.project))
  end

  defp retained(ctx) do
    old_id = "prior-#{System.unique_integer([:positive])}"
    GitFixture.git!(ctx.repo, ["checkout", "-b", "harness/" <> old_id])
    File.write!(Path.join(ctx.repo, "retained"), "useful work")
    GitFixture.git!(ctx.repo, ["add", "retained"])
    GitFixture.git!(ctx.repo, ["commit", "-m", "prior delivery"])
    GitFixture.git!(ctx.repo, ["checkout", "main"])

    :ok =
      ResultStore.record_run(%LogRecord{
        batch_id: "b",
        run_id: old_id,
        task_id: ctx.item.id,
        task_ids: [ctx.item.id],
        task_fingerprint: ctx.item.fingerprint,
        project_name: ctx.project.name,
        agent: :codex,
        model: "gpt-6-astra",
        adapter: Codex,
        state: :failed,
        reason: {:review_rejected, "report"},
        duration_ms: 1,
        review_report: "Exact reviewer report\nsecond line",
        verdict: :reject,
        agent_diff_size: 1
      })

    assert {:ok, [task]} = Attempts.attach(ctx.project, [ctx.task])

    assert {:ok, decision} =
             Decision.capture(ctx.project, task, %{
               adapter: "codex",
               model: "gpt-6-astra",
               action: "resume",
               source_run_id: old_id,
               reason: "Keep useful work"
             })

    {old_id, decision}
  end

  defp starter(owner, verdict) do
    Application.put_env(:harness, :run_starter, fn item, project, _adapter, opts ->
      send(owner, {:started, item, opts})

      Harness.Run.Supervisor.start_run(
        item,
        project,
        WitnessAdapter,
        Keyword.put(opts, :requested_model, nil) ++
          [
            adapter_opts: [command: :write],
            reviewer: WitnessAdapter,
            reviewer_adapter_opts: [command: {:review, verdict}],
            terminal_linger: 0
          ]
      )
    end)
  end

  defp drain(project), do: Oban.drain_queue(Harness.Oban, queue: Harness.Oban.queue_name(project), with_safety: false)
end
