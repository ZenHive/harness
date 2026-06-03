defmodule Harness.PipelineE2ETest do
  @moduledoc """
  Task 173: deterministic full-pipeline E2E — one assertion chain crossing every
  seam the pairwise suites (run_test, oban_dispatch_test, lander_test,
  run_landing_trigger_test) only test in isolation:

      roadmap task → Oban dispatch (Run.Worker.perform) → Run gen_statem in a
      real worktree → agent commit → check-stack verdict → (reviewer) →
      landing job → Lander.Worker.perform → ff-push to origin/<target> →
      rmap writeback

  No Postgres and no real agent CLIs: Oban interaction is seam-captured
  (`:oban_insert`) and the agent is `Harness.FakeAdapter` — but everything else
  is real. Real git repos with a bare origin, real worktrees, real check-stack
  execution, and real rmap against a throwaway fixture-roadmap copy.

  `async: false` — registers a project in the global `ProjectRegistry` and
  mutates `:harness` app env seams.
  """

  use ExUnit.Case, async: false

  alias Harness.CheckStack
  alias Harness.FakeAdapter
  alias Harness.GitFixture
  alias Harness.Lander.Worker, as: LanderWorker
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.Run.Supervisor, as: RunSupervisor
  alias Harness.Run.Worker, as: RunWorker
  alias Harness.Verification.Check

  @moduletag :tmp_dir

  @sample_roadmap Path.expand("../fixtures/sample_roadmap", __DIR__)

  # The cross-family reviewer double for the red path (the run_test.exs
  # ReviewerFixAdapter pattern): fixes the worktree inline — writes the
  # repair_marker the check stack demands, commits — exactly what a real
  # reviewer agent does when the implementer's work grades red.
  defmodule PipelineReviewerAdapter do
    @moduledoc false
    use Harness.AgentAdapter

    alias Harness.AgentAdapter
    alias Harness.AgentAdapter.Capabilities
    alias Harness.AgentAdapter.Invocation

    @impl AgentAdapter
    def capabilities, do: %Capabilities{}

    @impl AgentAdapter
    def rule_channel, do: :none

    @impl AgentAdapter
    def build_command(%Invocation{prompt: prompt}) do
      script =
        ~S(printf '%s' "$1" > reviewer_prompt.txt; echo fixed > repair_marker; git add reviewer_prompt.txt repair_marker; git commit -q -m "reviewer fix")

      {:ok, {"/bin/sh", ["-c", script, "harness-reviewer", prompt], []}}
    end
  end

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

    # Roadmap copy OUTSIDE the project repo: rmap writebacks (in_progress, done)
    # mutate tasks.toml, and a copy inside the checkout would trip the run's
    # checkout-pollution guard.
    roadmap_root = Path.join(tmp_dir, "roadmap-copy")
    File.mkdir_p!(roadmap_root)
    File.cp_r!(@sample_roadmap, roadmap_root)
    # rmap mutators (status writebacks) re-render ROADMAP.md and error if it is
    # missing; the read-only fixture ships without one, so give the copy a stub.
    File.write!(Path.join(roadmap_root, "ROADMAP.md"), "# Sample\n\n<!-- TASKS:BEGIN -->\n<!-- TASKS:END -->\n")

    install_seams(tmp_dir)

    %{origin: origin, repo: repo, roadmap_root: roadmap_root}
  end

  describe "green path" do
    test "roadmap task → dispatch → run → verify → land → writeback", ctx do
      # The FakeAdapter's :write deliverable satisfies this stack — the SAME
      # stack grades the run worktree and the lander's integrated tree.
      project =
        register_project(ctx.repo, ctx.roadmap_root, [
          %Check{name: "agent-output", command: "test", args: ["-f", "agent_output.txt"]}
        ])

      install_run_starter(adapter_opts: [command: :write], max_review_iterations: 0)
      run_id = "run-e2e-green"

      # ── dispatch → run → verify: synchronous; the green run settles inside ──
      assert :ok = RunWorker.perform(dispatch_job(project, run_id, 173))

      # The run claimed the task and, green-but-unlanded, left it in_progress.
      assert show_task(ctx.roadmap_root, "2")["status"] == "in_progress"

      # The settled green :auto run enqueued exactly one landing job on the
      # project's serialized landing queue.
      assert_receive {:oban_insert, changeset}, 5_000
      assert Ecto.Changeset.get_field(changeset, :queue) == "landing_" <> project.name

      landing_args = Ecto.Changeset.get_field(changeset, :args)
      assert landing_args["run_id"] == run_id
      assert landing_args["task_id"] == "2"
      assert landing_args["agent"] == "claude"
      assert landing_args["branch"] == "harness/" <> run_id
      assert landing_args["land_attempt"] == 1

      # ── land: checkout retained branch → re-verify → ff-push → writeback ──
      assert :ok = LanderWorker.perform(%Oban.Job{args: landing_args})

      # origin/<target> advanced to a tip carrying the agent's deliverable.
      landed_sha = origin_tip(ctx.origin)
      assert origin_tree(ctx.origin, landed_sha) =~ "agent_output.txt"

      # rmap writeback: done + verified + shipped_in == the landed SHA.
      task = show_task(ctx.roadmap_root, "2")
      assert task["status"] == "done"
      assert task["verified"] == true
      assert task["shipped_in"] == landed_sha
      assert task["delivered_by"] == "claude"

      # The run record persisted at settle time (File store under tmp).
      assert {:ok, [record]} = ResultStore.list_run_records(run_id: run_id)
      assert record.state == :done
      assert record.reason == :passed
      assert record.task_id == "2"
      assert record.project_name == project.name
    end
  end

  describe "red → reviewing → green path" do
    test "red implementer → reviewer fixes inline → re-verify green → land → writeback", ctx do
      # Red until a reviewer writes repair_marker: the :repair_noop implementer
      # only churns churn.txt, so the first verdict is red and the run routes
      # to :reviewing instead of settling :failed.
      project =
        register_project(ctx.repo, ctx.roadmap_root, [
          %Check{name: "repair-marker", command: "test", args: ["-f", "repair_marker"]}
        ])

      install_run_starter(
        adapter_opts: [command: :repair_noop],
        reviewer: PipelineReviewerAdapter,
        max_review_iterations: 2
      )

      run_id = "run-e2e-red"

      # Synchronous like the green path: red verdict → reviewer fixes inline →
      # mechanical re-verification grades green → the run settles :done.
      # (Result-level review_iterations/reviewer assertions live in run_test.exs;
      # this E2E asserts the cross-seam outcome.)
      assert :ok = RunWorker.perform(dispatch_job(project, run_id, 174))

      assert_receive {:oban_insert, changeset}, 5_000
      assert Ecto.Changeset.get_field(changeset, :queue) == "landing_" <> project.name

      landing_args = Ecto.Changeset.get_field(changeset, :args)
      assert landing_args["run_id"] == run_id
      assert landing_args["branch"] == "harness/" <> run_id

      # ── land: the integrated tree (implementer churn + reviewer fix) is
      #    re-verified by the SAME repair-marker stack before the ff-push ──
      assert :ok = LanderWorker.perform(%Oban.Job{args: landing_args})

      # The landed tip carries BOTH the implementer's churn and the reviewer's fix.
      landed_sha = origin_tip(ctx.origin)
      tree = origin_tree(ctx.origin, landed_sha)
      assert tree =~ "repair_marker"
      assert tree =~ "churn.txt"

      # rmap writeback lands on the reviewed run like any green run.
      task = show_task(ctx.roadmap_root, "2")
      assert task["status"] == "done"
      assert task["verified"] == true
      assert task["shipped_in"] == landed_sha
    end
  end

  # ── fixtures ──────────────────────────────────────────────────────────────

  # Registered with auto-landing onto main; the check stack is per-test (the
  # green path grades the implementer's deliverable, the red path a marker only
  # the reviewer writes).
  defp register_project(repo, roadmap_root, checks) do
    project = %{
      ProjectFixture.from_repo(repo,
        name: "pipeline-e2e-#{System.unique_integer([:positive])}",
        roadmap_path: roadmap_root,
        landing_policy: :auto,
        check_stack: %CheckStack{name: :e2e, checks: checks, workdir: ""}
      )
      | target_branch: "main"
    }

    :ok = ProjectRegistry.register(project)
    on_exit(fn -> ProjectRegistry.unregister(project.name) end)
    project
  end

  # App-env seams shared by every pipeline test: capture landing inserts, point
  # the result store at tmp, and disable the persisted landing-settings store so
  # the lander never reads the operator's real ~/.harness overrides.
  defp install_seams(tmp_dir) do
    test_pid = self()
    prior_result_store = Application.get_env(:harness, :result_store)
    prior_landing_settings = Application.get_env(:harness, :landing_settings)
    prior_landing_overrides = Application.get_env(:harness, :landing_overrides)

    Application.put_env(:harness, :oban_insert, fn changeset ->
      send(test_pid, {:oban_insert, changeset})
      {:ok, %Oban.Job{}}
    end)

    Application.put_env(:harness, :result_store, {ResultStore.File, root: Path.join(tmp_dir, "results")})
    Application.put_env(:harness, :landing_settings, false)
    Application.put_env(:harness, :landing_overrides, %{})

    on_exit(fn ->
      Application.delete_env(:harness, :oban_insert)
      Application.delete_env(:harness, :run_starter)
      restore(:result_store, prior_result_store)
      restore(:landing_settings, prior_landing_settings)
      restore(:landing_overrides, prior_landing_overrides)
    end)
  end

  # The adapter-identity trick: job args carry the Claude adapter (so the
  # AgentRegistry gate and rmap's `--to` target are satisfied), and this seam
  # swaps in FakeAdapter + test opts on the way into the REAL RunSupervisor.
  # No real agent CLI ever spawns.
  defp install_run_starter(test_opts) do
    base_dir = GitFixture.tmp_base()

    run_opts =
      Keyword.merge(
        [
          base_dir: base_dir,
          total_timeout: 30_000,
          idle_timeout: 10_000,
          lifetime_timeout: 30_000,
          verification_timeout: 10_000,
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

  defp origin_tree(origin, sha), do: GitFixture.git!(origin, ["ls-tree", "--name-only", sha])

  defp show_task(roadmap_root, id) do
    assert {output, 0} = System.cmd("rmap", ["show", id, "--json"], cd: roadmap_root, stderr_to_stdout: true)
    Jason.decode!(output)
  end

  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)
end
