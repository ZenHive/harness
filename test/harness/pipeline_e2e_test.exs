defmodule Harness.PipelineE2ETest do
  @moduledoc """
  Deterministic full-pipeline E2E for the agent-gate workflow — one assertion
  chain crossing every seam the pairwise suites (run_test, oban_dispatch_test,
  lander_test, run_landing_trigger_test, audit_test) only test in isolation:

      roadmap task → Oban dispatch (Run.Worker.perform) → Run gen_statem in a
      real worktree → implementer commit → reviewer AI (THE gate, verdict
      artifact) → landing job → Lander.Worker.perform → ff-push to
      origin/<target> → audit job enqueue → rmap writeback

  No Postgres and no real agent CLIs: Oban interaction is seam-captured
  (`:oban_insert`) and both the implementer and the reviewer are
  `Harness.FakeAdapter` doubles — but everything else is real. Real git repos
  with a bare origin, real worktrees, a real `.harness/review.json` verdict
  artifact, and real rmap against a fixture roadmap seeded on `origin/main`
  (durable writeback requires `roadmap/tasks.toml` on the target branch).

  `async: false` — registers a project in the global `ProjectRegistry` and
  mutates `:harness` app env seams.
  """

  use ExUnit.Case, async: false

  alias Harness.FakeAdapter
  alias Harness.GitFixture
  alias Harness.Lander.Worker, as: LanderWorker
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.Run.Supervisor, as: RunSupervisor
  alias Harness.Run.Worker, as: RunWorker

  @moduletag :tmp_dir

  @sample_roadmap Path.expand("../fixtures/sample_roadmap", __DIR__)

  setup_all do
    if !System.find_executable("rmap") do
      flunk("""
      rmap CLI not found on PATH.

      The pipeline E2E exercises real rmap ingestion and writeback —
      Harness.Roadmap shells out to `rmap`. Install it (a Rust binary,
      `cargo install` from the rmap repo) and ensure it is on PATH.
      """)
    end

    :ok
  end

  setup %{tmp_dir: tmp_dir} do
    # Real project repo + bare origin, so the lander's ff-push is assertable.
    %{origin: origin, repo: repo} = GitFixture.init_with_origin()
    seed_roadmap!(repo)

    install_seams(tmp_dir)

    %{origin: origin, repo: repo, roadmap_root: repo}
  end

  describe "approve path — reviewer approves untouched work" do
    test "roadmap task → dispatch → run → reviewer gate → land → audit enqueue → writeback", ctx do
      project = register_project(ctx.repo, ctx.roadmap_root)

      install_run_starter(
        adapter_opts: [command: :write],
        reviewer_adapter_opts: [command: {:review, "approve"}]
      )

      run_id = "run-e2e-approve"

      # ── dispatch → run → reviewer gate: synchronous; the approved run settles inside ──
      assert :ok = RunWorker.perform(dispatch_job(project, run_id, 173))

      # The run claimed the task and, approved-but-unlanded, left it in_progress.
      assert show_task(ctx.roadmap_root, "2")["status"] == "in_progress"

      # The reviewer-approved :auto run enqueued exactly one landing job on the
      # project's serialized landing queue, carrying the reviewer identity for
      # the audit stage's third-family selection.
      assert_receive {:oban_insert, landing}, 5_000
      assert Ecto.Changeset.get_field(landing, :queue) == "landing_" <> project.name

      landing_args = Ecto.Changeset.get_field(landing, :args)
      assert landing_args["run_id"] == run_id
      assert landing_args["task_id"] == "2"
      assert landing_args["agent"] == "claude"
      assert landing_args["branch"] == "harness/" <> run_id
      assert landing_args["land_attempt"] == 1
      # FakeAdapter has no agent-family registration → reviewer rides as nil.
      assert Map.fetch!(landing_args, "reviewer") == nil

      pre_land_tip = origin_tip(ctx.origin)

      # ── land: rebase → ff-push (no re-verification — the reviewer WAS the gate) ──
      assert :ok = LanderWorker.perform(%Oban.Job{args: landing_args})

      # origin/<target> advanced to a tip carrying the implementer's deliverable.
      refute origin_tip(ctx.origin) == pre_land_tip

      task = show_task(ctx.roadmap_root, "2")
      shipped_sha = task["shipped_in"]
      assert origin_tree(ctx.origin, shipped_sha) =~ "agent_output.txt"

      # The successful push enqueued one post-merge audit job with the pre-land
      # base, so the audit AI can compute the unaudited range mechanically.
      assert_receive {:oban_insert, audit}, 5_000
      assert Ecto.Changeset.get_field(audit, :queue) == "audit"
      assert Ecto.Changeset.get_field(audit, :worker) == "Harness.Audit.Worker"

      audit_args = Ecto.Changeset.get_field(audit, :args)
      assert audit_args["project_name"] == project.name
      assert audit_args["base_sha"] == pre_land_tip
      assert audit_args["implementer"] == "claude"

      # rmap writeback: done + verified + shipped_in == the landed code SHA.
      assert task["status"] == "done"
      assert task["verified"] == true
      assert task["delivered_by"] == "claude"

      # The run record persisted at settle time (File store under tmp) carries
      # the reviewer's verdict, zero-fix diff, and ratings.
      assert {:ok, [record]} = ResultStore.list_run_records(run_id: run_id)
      assert record.state == :done
      assert record.reason == :approved
      assert record.verdict == :approve
      assert record.reviewer_diff_size == 0
      assert record.review_ratings == FakeAdapter.review_ratings()
      assert record.task_id == "2"
      assert record.project_name == project.name
    end
  end

  describe "fix-and-approve path — reviewer fixes inline, then approves" do
    test "implementer churn → reviewer fix commits → land carries both → writeback", ctx do
      project = register_project(ctx.repo, ctx.roadmap_root)

      # The implementer only churns churn.txt; the reviewer (near-never-reject)
      # fixes the work inline — its own edit, committed by harness after the
      # review — and approves.
      install_run_starter(
        adapter_opts: [command: :repair_noop],
        reviewer_adapter_opts: [command: {:review_with_fix, "approve"}]
      )

      run_id = "run-e2e-fix"

      assert :ok = RunWorker.perform(dispatch_job(project, run_id, 174))

      assert_receive {:oban_insert, landing}, 5_000
      assert Ecto.Changeset.get_field(landing, :queue) == "landing_" <> project.name

      landing_args = Ecto.Changeset.get_field(landing, :args)
      assert landing_args["run_id"] == run_id

      assert :ok = LanderWorker.perform(%Oban.Job{args: landing_args})

      task = show_task(ctx.roadmap_root, "2")
      shipped_sha = task["shipped_in"]
      tree = origin_tree(ctx.origin, shipped_sha)
      assert tree =~ "churn.txt"
      assert tree =~ "reviewer_fix.txt"
      # The verdict artifact never rides in the deliverable.
      refute tree =~ ".harness"

      # The audit job still fires — fixes-then-approve lands like any approval.
      assert_receive {:oban_insert, audit}, 5_000
      assert Ecto.Changeset.get_field(audit, :queue) == "audit"

      # rmap writeback lands on the reviewed run like any approved run.
      assert task["status"] == "done"
      assert task["verified"] == true
      assert shipped_sha != ""

      # The record's reviewer-fix diff is the "how much fixing was needed" KPI signal.
      assert {:ok, [record]} = ResultStore.list_run_records(run_id: run_id)
      assert record.verdict == :approve
      assert record.reviewer_diff_size > 0
    end
  end

  describe "reject path — the gate holds" do
    test "reviewer rejects → run fails → task back to pending → nothing lands", ctx do
      project = register_project(ctx.repo, ctx.roadmap_root)

      install_run_starter(
        adapter_opts: [command: :write],
        reviewer_adapter_opts: [command: {:review, "reject"}]
      )

      run_id = "run-e2e-reject"
      report = FakeAdapter.review_report("reject")

      # The worker cancels (settled failure, never retried) with the reviewer's report.
      assert {:cancel, {:review_rejected, ^report}} = RunWorker.perform(dispatch_job(project, run_id, 175))

      # The task went back to the queue for re-dispatch — rejection is a queue
      # cycle with information, not a dead end.
      assert show_task(ctx.roadmap_root, "2")["status"] == "pending"

      # No landing job, no audit job, and no agent deliverable on origin.
      refute_receive {:oban_insert, _changeset}, 200
      refute origin_tree(ctx.origin, origin_tip(ctx.origin)) =~ "agent_output.txt"

      # The rejection persisted with the reviewer's report for the next dispatch.
      assert {:ok, [record]} = ResultStore.list_run_records(run_id: run_id)
      assert record.state == :failed
      assert record.reason == {:review_rejected, report}
      assert record.verdict == :reject
      assert record.review_report == report
    end
  end

  # ── fixtures ──────────────────────────────────────────────────────────────

  # Registered with auto-landing onto main; the reviewer is the only gate, so
  # there is no check stack — check_command is a free-text hint for the
  # (faked) reviewer prompt.
  defp register_project(repo, roadmap_root) do
    project =
      ProjectFixture.from_repo(repo,
        name: "pipeline-e2e-#{System.unique_integer([:positive])}",
        roadmap_path: roadmap_root,
        landing_policy: :auto,
        target_branch: "main",
        check_command: "true"
      )

    :ok = ProjectRegistry.register(project)
    on_exit(fn -> ProjectRegistry.unregister(project.name) end)
    project
  end

  # App-env seams shared by every pipeline test: capture Oban inserts (landing +
  # audit), point the result store at tmp, and drop to the ephemeral settings
  # store so the lander reads no persisted landing overrides (and never touches
  # the operator's real ~/.harness state).
  defp install_seams(tmp_dir) do
    test_pid = self()
    prior_result_store = Application.get_env(:harness, :result_store)
    prior_settings_store = Application.get_env(:harness, :settings_store)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      send(test_pid, {:oban_insert, changeset})
      {:ok, %Oban.Job{}}
    end)

    Application.put_env(:harness, :result_store, {ResultStore.Memory, root: Path.join(tmp_dir, "results")})
    Application.put_env(:harness, :settings_store, false)

    on_exit(fn ->
      Application.delete_env(:harness, :oban_insert)
      Application.delete_env(:harness, :run_starter)
      restore(:result_store, prior_result_store)
      restore(:settings_store, prior_settings_store)
    end)
  end

  # The adapter-identity trick: job args carry the Claude adapter (so the
  # AgentRegistry gate and rmap's `--to` target are satisfied), and this seam
  # swaps in FakeAdapter — implementer AND reviewer — plus test opts on the way
  # into the REAL RunSupervisor. No real agent CLI ever spawns.
  defp install_run_starter(test_opts) do
    base_dir = GitFixture.tmp_base()

    run_opts =
      Keyword.merge(
        [
          base_dir: base_dir,
          reviewer: FakeAdapter,
          total_timeout: 30_000,
          idle_timeout: 10_000,
          lifetime_timeout: 30_000,
          terminal_linger: 100
        ],
        test_opts
      )

    Application.put_env(:harness, :run_starter, fn item, run_project, _adapter, opts ->
      RunSupervisor.start_run(item, run_project, FakeAdapter, opts ++ run_opts)
    end)
  end

  defp dispatch_job(project, run_id, job_id) do
    %Oban.Job{
      id: job_id,
      attempt: 1,
      args: %{
        "project_name" => project.name,
        "item_id" => "2",
        "adapter_module" => "Elixir.Harness.AgentAdapter.Claude",
        "run_id" => run_id
      }
    }
  end

  defp origin_tip(origin), do: origin |> GitFixture.git!(["rev-parse", "refs/heads/main"]) |> String.trim()

  defp origin_tree(origin, sha), do: GitFixture.git!(origin, ["ls-tree", "-r", "--name-only", sha])

  defp seed_roadmap!(repo) do
    File.cp_r!(@sample_roadmap, repo)

    File.write!(
      Path.join(repo, "ROADMAP.md"),
      "# Sample\n\n<!-- TASKS:BEGIN -->\n<!-- TASKS:END -->\n"
    )

    tasks_path = Path.join(repo, "roadmap/tasks.toml")

    assert {_, 0} =
             System.cmd("rmap", ["render", "--tasks-path", tasks_path], stderr_to_stdout: true)

    GitFixture.git!(repo, ["add", "-A"])
    GitFixture.git!(repo, ["commit", "-q", "-m", "seed roadmap"])
    GitFixture.git!(repo, ["push", "-q", "origin", "main"])
  end

  defp show_task(roadmap_root, id) do
    assert {output, 0} = System.cmd("rmap", ["show", id, "--json"], cd: roadmap_root, stderr_to_stdout: true)
    Jason.decode!(output)
  end

  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)
end
