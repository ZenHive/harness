defmodule Harness.LanderTest.FlakyStore do
  @moduledoc false

  @behaviour Harness.ResultStore

  alias Harness.AgentKPI
  alias Harness.Batch.Result, as: BatchResult
  alias Harness.Run.LogRecord

  @type state :: %{record: LogRecord.t(), marks: non_neg_integer()}

  @spec start_link(LogRecord.t()) :: {:ok, Agent.agent()}
  def start_link(%LogRecord{} = record), do: Agent.start_link(fn -> %{record: record, marks: 0} end)

  @spec mark_count(Agent.agent()) :: non_neg_integer()
  def mark_count(agent), do: Agent.get(agent, & &1.marks)

  @impl Harness.ResultStore
  @spec record_run(LogRecord.t(), keyword()) :: :ok
  def record_run(%LogRecord{} = record, opts), do: update(opts, &%{&1 | record: record})

  @impl Harness.ResultStore
  @spec save_batch(BatchResult.t(), keyword()) :: :ok
  def save_batch(%BatchResult{}, _opts), do: :ok

  @impl Harness.ResultStore
  @spec load_batch(String.t(), keyword()) :: {:error, :not_found}
  def load_batch(_batch_id, _opts), do: {:error, :not_found}

  @impl Harness.ResultStore
  @spec list_run_records(Harness.ResultStore.filters(), keyword()) :: {:ok, [LogRecord.t()]}
  def list_run_records(filters, opts) do
    record = Agent.get(fetch_agent!(opts), & &1.record)

    if Keyword.get(filters, :run_id) in [nil, record.run_id], do: {:ok, [record]}, else: {:ok, []}
  end

  @impl Harness.ResultStore
  @spec delete_run(String.t(), keyword()) :: :ok
  def delete_run(_run_id, _opts), do: :ok

  @impl Harness.ResultStore
  @spec mark_landed(String.t(), String.t(), keyword()) :: :ok
  def mark_landed(_run_id, sha, opts) do
    update(opts, fn %{record: record, marks: marks} ->
      landed_sha = if marks == 0, do: nil, else: sha
      %{record: %{record | landed_sha: landed_sha}, marks: marks + 1}
    end)
  end

  @impl Harness.ResultStore
  @spec aggregate_by_agent(keyword(), keyword()) :: {:ok, AgentKPI.t()}
  def aggregate_by_agent(_query_opts, _opts), do: {:ok, %{}}

  @impl Harness.ResultStore
  @spec aggregate_reviewer_reliability(keyword(), keyword()) :: {:ok, AgentKPI.reviewer_ledger()}
  def aggregate_reviewer_reliability(_query_opts, _opts), do: {:ok, %{}}

  @impl Harness.ResultStore
  @spec aggregate_by_facet(keyword(), keyword()) :: {:ok, [Harness.ResultStore.facet_group()]}
  def aggregate_by_facet(_query_opts, _opts), do: {:ok, []}

  @spec update(keyword(), (state() -> state())) :: :ok
  defp update(opts, fun), do: Agent.update(fetch_agent!(opts), fun)

  @spec fetch_agent!(keyword()) :: Agent.agent()
  defp fetch_agent!(opts), do: Keyword.fetch!(opts, :agent)
end

defmodule Harness.LanderTest do
  # async: false because tests mutate app env seams and global notification sinks.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Harness.AgentAdapter.Claude
  alias Harness.Dashboard.OpsFeed
  alias Harness.Dashboard.OpsFeed.Op
  alias Harness.GitFixture
  alias Harness.Lander
  alias Harness.Lander.Worker, as: LanderWorker
  alias Harness.LanderTest.FlakyStore
  alias Harness.Notification.Event
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.ResultStore.Memory
  alias Harness.Run.LogRecord
  alias Harness.Worktree

  @moduletag :tmp_dir
  @executable_file_mode 0o755

  # ── git fixture: a bare `origin` + a working clone, so the lander's
  #    ff-push to `origin/<target>` is real and assertable. ──────────────

  defp git(repo, args), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp sha(repo, ref), do: repo |> GitFixture.git!(["rev-parse", ref]) |> String.trim()

  @spec branch_exists?(String.t(), String.t()) :: boolean()
  defp branch_exists?(repo, branch) do
    {_output, status} = git(repo, ["show-ref", "--verify", "--quiet", "refs/heads/" <> branch])
    status == 0
  end

  @spec landing_root(map()) :: String.t()
  defp landing_root(ctx) do
    Path.join([ctx.worktree_base, Path.basename(ctx.repo), "landing"])
  end

  defp ancestor?(repo, maybe_ancestor, descendant) do
    {_output, status} = git(repo, ["merge-base", "--is-ancestor", maybe_ancestor, descendant])
    status == 0
  end

  setup %{tmp_dir: tmp_dir} do
    %{origin: origin, repo: repo} = GitFixture.init_with_origin()
    worktree_base = Path.join(tmp_dir, "worktrees")
    Application.put_env(:harness, :worktree, base_dir: worktree_base)

    base_sha = sha(repo, "HEAD")

    project = %Project{
      name: "demo",
      source: {:local, repo},
      roadmap_path: tmp_dir,
      target_branch: "main"
    }

    # the settled run's deliverable: Harness.Run's retained implementer
    # worktree on harness/<run-id>, with one extra commit.
    {:ok, run_worktree} = Worktree.create(project, id: "run-x")
    File.write!(Path.join(run_worktree.path, "feature.txt"), "work\n")
    GitFixture.git!(run_worktree.path, ["add", "."])
    GitFixture.git!(run_worktree.path, ["commit", "-m", "agent work"])
    branch_tip = sha(run_worktree.path, "HEAD")

    request = %{
      project: project,
      run_id: "run-x",
      task_id: "1",
      agent: :claude,
      reviewer: :codex,
      branch: "harness/run-x"
    }

    store = {Memory, scope: {:lander_test, self(), System.unique_integer([:positive])}}
    Application.put_env(:harness, :result_store, store)

    on_exit(fn ->
      Application.delete_env(:harness, :result_store)
      Application.delete_env(:harness, :worktree)
      Memory.reset(elem(store, 1))
    end)

    %{
      origin: origin,
      repo: repo,
      base_sha: base_sha,
      branch_tip: branch_tip,
      project: project,
      request: request,
      run_worktree: run_worktree,
      worktree_base: worktree_base
    }
  end

  describe "land/1 — fast-forward path (target unmoved)" do
    test "pushes the branch tip to origin/<target>", ctx do
      assert {:landed, landed} = Lander.land(ctx.request)
      assert landed == ctx.branch_tip
      assert sha(ctx.origin, "refs/heads/main") == ctx.branch_tip
    end

    test "prunes the retained run branch and implementer worktree but leaves the landing root", ctx do
      assert branch_exists?(ctx.repo, ctx.request.branch)
      assert File.dir?(ctx.run_worktree.path)

      assert {:landed, landed} = Lander.land(ctx.request)

      assert landed == ctx.branch_tip
      refute branch_exists?(ctx.repo, ctx.request.branch)
      refute File.exists?(ctx.run_worktree.path)
      assert File.dir?(landing_root(ctx))
    end

    test "persists landed_sha on the run record", ctx do
      assert :ok = ResultStore.record_run(log_record("run-x"))

      assert {:landed, landed} = Lander.land(ctx.request)

      assert {:ok, [record]} = ResultStore.list_run_records(run_id: "run-x")
      assert record.landed_sha == landed
    end

    test "swallows run-prune refusal after the push and leaves landed state intact", ctx do
      {:ok, _} = Registry.register(Harness.Run.Registry, ctx.request.run_id, nil)

      log =
        capture_log(fn ->
          assert {:landed, landed} = Lander.land(ctx.request)
          assert landed == ctx.branch_tip
        end)

      assert log =~ "run cleanup failed after landing run run-x"
      assert sha(ctx.origin, "refs/heads/main") == ctx.branch_tip
      assert branch_exists?(ctx.repo, ctx.request.branch)
      assert File.dir?(ctx.run_worktree.path)
    end

    test "retries landed_sha write when a verification read still sees nil", ctx do
      {:ok, agent} = FlakyStore.start_link(log_record("run-x"))
      Application.put_env(:harness, :result_store, {FlakyStore, agent: agent})

      assert {:landed, landed} = Lander.land(ctx.request)

      assert FlakyStore.mark_count(agent) == 2
      assert {:ok, [record]} = ResultStore.list_run_records(run_id: "run-x")
      assert record.landed_sha == landed
    end

    test "broadcasts started + settled(:landed) on the dashboard ops feed (task 243)", ctx do
      :ok = OpsFeed.subscribe()

      assert {:landed, landed} = Lander.land(ctx.request)

      assert_receive {:harness_op, %Op{kind: :land, stage: :landing, run_id: "run-x", target: "main"}}
      assert_receive {:harness_op, %Op{kind: :land, stage: :landed, run_id: "run-x", sha: ^landed}}
    end
  end

  describe "land/1 — post-push local target sync" do
    test "fast-forwards local target ref without touching the checkout when operator is off target", ctx do
      GitFixture.git!(ctx.repo, ["checkout", "-b", "side"])
      side_head = sha(ctx.repo, "HEAD")

      assert {:landed, landed} = Lander.land(ctx.request)

      assert landed == ctx.branch_tip
      assert sha(ctx.repo, "main") == landed
      assert sha(ctx.repo, "HEAD") == side_head
      assert String.trim(GitFixture.git!(ctx.repo, ["branch", "--show-current"])) == "side"
      refute File.exists?(Path.join(ctx.repo, "feature.txt"))
    end

    test "fast-forwards HEAD when operator is on target with a clean tree", ctx do
      assert String.trim(GitFixture.git!(ctx.repo, ["branch", "--show-current"])) == "main"

      assert {:landed, landed} = Lander.land(ctx.request)

      assert landed == ctx.branch_tip
      assert sha(ctx.repo, "HEAD") == landed
      assert File.read!(Path.join(ctx.repo, "feature.txt")) == "work\n"
    end

    test "skips and notifies when operator is on target with a dirty tree", ctx do
      put_capture_sink()
      File.write!(Path.join(ctx.repo, "scratch.txt"), "local\n")

      assert {:landed, landed} = Lander.land(ctx.request)

      assert landed == ctx.branch_tip
      assert sha(ctx.repo, "HEAD") == ctx.base_sha
      assert File.read!(Path.join(ctx.repo, "scratch.txt")) == "local\n"
      assert_receive {:notify, %Event{type: :local_sync_skipped, outcome: reason}}
      assert reason =~ "local main behind origin by 1"
      assert reason =~ "sync manually"
    end

    test "leaves a non-ff local target untouched and notifies instead of forcing it", ctx do
      put_capture_sink()
      File.write!(Path.join(ctx.repo, "local.txt"), "operator\n")
      GitFixture.git!(ctx.repo, ["add", "."])
      GitFixture.git!(ctx.repo, ["commit", "-m", "operator work"])
      local_head = sha(ctx.repo, "HEAD")

      assert {:landed, landed} = Lander.land(ctx.request)

      assert landed == ctx.branch_tip
      assert sha(ctx.origin, "refs/heads/main") == landed
      assert sha(ctx.repo, "HEAD") == local_head
      assert File.read!(Path.join(ctx.repo, "local.txt")) == "operator\n"
      assert_receive {:notify, %Event{type: :local_sync_skipped, outcome: reason}}
      assert reason =~ "local main behind origin by 1"
      assert reason =~ "sync manually"
    end
  end

  describe "land/1 — rebase path (target moved under the branch)" do
    test "rebases onto origin/<target>, then ff-pushes", ctx do
      # advance origin/main past the branch's fork point (non-conflicting file).
      File.write!(Path.join(ctx.repo, "main_moved.txt"), "x\n")
      GitFixture.git!(ctx.repo, ["add", "."])
      GitFixture.git!(ctx.repo, ["commit", "-m", "main moves"])
      GitFixture.git!(ctx.repo, ["push", "origin", "main"])
      moved_main = sha(ctx.origin, "refs/heads/main")
      GitFixture.git!(ctx.repo, ["checkout", "main"])

      assert {:landed, landed} = Lander.land(ctx.request)
      # the landed tip is the rebased branch, not the pre-rebase tip.
      refute landed == ctx.branch_tip
      assert sha(ctx.origin, "refs/heads/main") == landed
      # integrated history contains BOTH the moved-main commit and the agent work.
      assert ancestor?(ctx.origin, moved_main, "refs/heads/main")
      {_out, 0} = git(ctx.origin, ["cat-file", "-e", landed <> ":feature.txt"])
    end

    test "reassigns stale roadmap task ids filed concurrently before pushing", ctx do
      File.mkdir_p!(Path.join(ctx.run_worktree.path, "roadmap"))
      File.write!(Path.join(ctx.run_worktree.path, "roadmap/tasks.toml"), roadmap_toml("200", "Stale branch task"))
      File.write!(Path.join(ctx.run_worktree.path, "ROADMAP.md"), roadmap_markers())
      GitFixture.git!(ctx.run_worktree.path, ["add", "."])
      GitFixture.git!(ctx.run_worktree.path, ["commit", "-m", "file stale roadmap task"])

      File.mkdir_p!(Path.join(ctx.repo, "roadmap"))
      File.write!(Path.join(ctx.repo, "roadmap/tasks.toml"), roadmap_toml("200", "Target task"))
      File.write!(Path.join(ctx.repo, "ROADMAP.md"), roadmap_markers())
      render_roadmap!(ctx.repo)
      GitFixture.git!(ctx.repo, ["add", "."])
      GitFixture.git!(ctx.repo, ["commit", "-m", "file target roadmap task"])
      GitFixture.git!(ctx.repo, ["push", "origin", "main"])

      put_resolver(fn %{path: path}, _opts ->
        File.write!(
          Path.join(path, "roadmap/tasks.toml"),
          roadmap_toml("200", "Target task") <> "\n" <> task_toml("200", "Stale branch task")
        )

        File.write!(Path.join(path, "ROADMAP.md"), roadmap_markers())
        :ok
      end)

      assert {:landed, landed} = Lander.land(ctx.request)

      toml = GitFixture.git!(ctx.origin, ["show", landed <> ":roadmap/tasks.toml"])
      assert toml =~ ~s(id = "200")
      assert toml =~ ~s(title = "Target task")
      assert toml =~ ~s(id = "201")
      assert toml =~ ~s(title = "Stale branch task")
    end
  end

  describe "land/1 — non-ff push race" do
    test "returns push_rejected when origin advances during the final push", ctx do
      stage_origin_advancing_hook(ctx.origin)

      assert {:push_rejected, output} = Lander.land(ctx.request)
      assert output =~ "remote advanced by hook"
      refute sha(ctx.origin, "refs/heads/main") == ctx.branch_tip
    end
  end

  describe "land/1 — post-merge audit trigger" do
    test "a successful land enqueues one audit job carrying the pre-land target tip", ctx do
      test_pid = self()

      Application.put_env(:harness, :oban_insert, fn changeset ->
        job = Ecto.Changeset.apply_action!(changeset, :insert)
        send(test_pid, {:audit_insert, job})
        {:ok, job}
      end)

      on_exit(fn -> Application.delete_env(:harness, :oban_insert) end)

      assert {:landed, _landed} = Lander.land(ctx.request)

      assert_receive {:audit_insert, %Oban.Job{args: args, worker: "Harness.Audit.Worker", queue: "audit"}}

      assert args == %{
               "project_name" => "demo",
               "base_sha" => ctx.base_sha,
               "implementer" => "claude",
               "reviewer" => "codex"
             }
    end
  end

  describe "land/1 — conflict on rebase (Task 189: merge-resolver agent)" do
    # Stages a real rebase conflict on README.md: the branch and origin/main
    # both edit it from a shared base. Returns the moved-main sha for assertions.
    defp stage_conflict(ctx) do
      File.write!(Path.join(ctx.run_worktree.path, "README.md"), "branch side\n")
      GitFixture.git!(ctx.run_worktree.path, ["add", "."])
      GitFixture.git!(ctx.run_worktree.path, ["commit", "-m", "branch readme"])

      File.write!(Path.join(ctx.repo, "README.md"), "main side\n")
      GitFixture.git!(ctx.repo, ["add", "."])
      GitFixture.git!(ctx.repo, ["commit", "-m", "main readme"])
      GitFixture.git!(ctx.repo, ["push", "origin", "main"])
      sha(ctx.origin, "refs/heads/main")
    end

    defp put_resolver(fun) do
      Application.put_env(:harness, :lander_resolver, fun)
      on_exit(fn -> Application.delete_env(:harness, :lander_resolver) end)
    end

    test "a resolver that reconciles the markers lands both sides", ctx do
      moved_main = stage_conflict(ctx)

      # The injected resolver edits the open landing worktree to keep BOTH sides
      # (exactly what a real merge-resolver agent would do), leaving no markers.
      put_resolver(fn %{path: path}, _opts ->
        File.write!(Path.join(path, "README.md"), "main side\nbranch side\n")
        :ok
      end)

      assert {:landed, landed} = Lander.land(ctx.request)
      # the conflict was resolved + continued, then ff-pushed.
      assert sha(ctx.origin, "refs/heads/main") == landed
      assert ancestor?(ctx.origin, moved_main, "refs/heads/main")
      {readme, 0} = git(ctx.origin, ["show", landed <> ":README.md"])
      assert readme =~ "main side"
      assert readme =~ "branch side"
    end

    test "a resolver that leaves conflict markers NEVER lands — falls back to {:conflict, _}", ctx do
      moved_main = stage_conflict(ctx)

      # The agent "ran" but left a marker behind; the mechanical gate must catch
      # it, abort the rebase, and fall back rather than land a poisoned tree.
      put_resolver(fn %{path: path}, _opts ->
        File.write!(Path.join(path, "README.md"), "<<<<<<< HEAD\nmain side\n=======\nbranch side\n>>>>>>> x\n")
        :ok
      end)

      assert {:conflict, _output} = Lander.land(ctx.request)
      assert sha(ctx.origin, "refs/heads/main") == moved_main
    end

    test "an unavailable/declining resolver falls back to {:conflict, _}, origin untouched", ctx do
      moved_main = stage_conflict(ctx)
      put_resolver(fn _worktree, _opts -> {:error, :no_resolver} end)

      assert {:conflict, _output} = Lander.land(ctx.request)
      assert sha(ctx.origin, "refs/heads/main") == moved_main
      assert branch_exists?(ctx.repo, ctx.request.branch)
      assert File.dir?(ctx.run_worktree.path)
    end

    test "manual reland conflict retains the branch, notifies, and does not redispatch", ctx do
      moved_main = stage_conflict(ctx)
      conflicting_tip = sha(ctx.run_worktree.path, "HEAD")
      put_resolver(fn _worktree, _opts -> {:error, :no_resolver} end)
      put_capture_sink()
      tasks_path = Path.join(ctx.project.roadmap_path, "roadmap/tasks.toml")
      File.mkdir_p!(Path.dirname(tasks_path))

      roadmap_before =
        "1"
        |> roadmap_toml("Manual reland task")
        |> String.replace(~s(status = "pending"), ~s(status = "in_progress"), global: false)

      File.write!(tasks_path, roadmap_before)
      :ok = ProjectRegistry.register(ctx.project)
      parent = self()

      Application.put_env(:harness, :roadmap_ingest, fn selector, opts ->
        send(parent, {:unexpected_ingest, selector, opts})
        {:error, :unexpected_ingest}
      end)

      Application.put_env(:harness, :run_starter, fn item, project, adapter, opts ->
        send(parent, {:unexpected_run_start, item, project, adapter, opts})
        {:error, :unexpected_run_start}
      end)

      on_exit(fn ->
        ProjectRegistry.unregister(ctx.project.name)
        Application.delete_env(:harness, :roadmap_ingest)
        Application.delete_env(:harness, :run_starter)
      end)

      args =
        ctx.request
        |> Map.take([:run_id, :task_id, :branch])
        |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
        |> Map.merge(%{
          "project_name" => ctx.project.name,
          "agent" => "claude",
          "reviewer" => "codex",
          "land_attempt" => 1,
          "manual_reland" => true
        })

      assert {:cancel, {:manual_reland_conflict, output}} = LanderWorker.perform(%Oban.Job{args: args})
      assert output =~ "CONFLICT"
      assert sha(ctx.origin, "refs/heads/main") == moved_main
      assert branch_exists?(ctx.repo, ctx.request.branch)
      assert File.dir?(ctx.run_worktree.path)
      refute ancestor?(ctx.origin, conflicting_tip, "refs/heads/main")

      assert_receive {:notify,
                      %Event{
                        type: :conflict,
                        task_id: "1",
                        run_id: "run-x",
                        branch: "harness/run-x",
                        land_attempt: 1,
                        outcome: ^output
                      }}

      refute_receive {:unexpected_ingest, _selector, _opts}, 300
      refute_receive {:unexpected_run_start, _item, _project, _adapter, _opts}, 300
      assert File.read!(tasks_path) == roadmap_before
    end

    test "worker retains a resolver-disabled conflict (never re-dispatches), leaving origin untouched", ctx do
      moved_main = stage_conflict(ctx)
      conflicting_tip = sha(ctx.run_worktree.path, "HEAD")
      put_resolver(fn _worktree, _opts -> {:error, :no_resolver} end)
      :ok = ProjectRegistry.register(ctx.project)
      on_exit(fn -> ProjectRegistry.unregister(ctx.project.name) end)

      args =
        ctx.request
        |> Map.take([:run_id, :task_id, :branch])
        |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
        |> Map.merge(%{
          "project_name" => ctx.project.name,
          "agent" => "claude",
          "reviewer" => "codex",
          "land_attempt" => 1
        })

      assert {:cancel, {:conflict_retained, reason}} = LanderWorker.perform(%Oban.Job{args: args})
      assert reason =~ "dispatch-reland"
      assert sha(ctx.origin, "refs/heads/main") == moved_main
      refute ancestor?(ctx.origin, conflicting_tip, "refs/heads/main")
    end
  end

  describe "land/1 — guards" do
    test "skips a {:github, _} source it cannot push to", ctx do
      gh = %Project{
        name: "gh",
        source: {:github, "https://example.com/x.git"},
        roadmap_path: ctx.request.project.roadmap_path,
        target_branch: "main"
      }

      assert {:skipped, :github_source} = Lander.land(%{ctx.request | project: gh})
    end

    test "errors when the project declares no target_branch", ctx do
      request = %{ctx.request | project: %{ctx.project | target_branch: nil}}
      assert {:error, :no_target_branch} = Lander.land(request)
    end
  end

  describe "enqueue/1 + landing_args/2 (operator Re-land)" do
    test "landing_args/2 reconstructs the landing job from a persisted record" do
      record = %LogRecord{
        batch_id: "b",
        run_id: "run-abc",
        task_id: "42",
        task_fingerprint: "fp-42",
        adapter: Claude,
        state: :done,
        reason: :approved,
        duration_ms: 1,
        agent: :claude
      }

      project = %Project{name: "demo", source: {:local, "/tmp/x"}, roadmap_path: "/tmp", target_branch: "main"}

      assert Lander.landing_args(record, project) == %{
               "project_name" => "demo",
               "run_id" => "run-abc",
               "task_id" => "42",
               "task_fingerprint" => "fp-42",
               "agent" => "claude",
               "reviewer" => nil,
               "branch" => "harness/run-abc",
               "land_attempt" => 1,
               "manual_reland" => true
             }
    end

    test "enqueue/1 returns :not_found for an unrecorded run_id" do
      assert {:error, :not_found} = Lander.enqueue("__no_such_run__")
    end
  end

  defp put_capture_sink do
    Application.put_env(:harness, :notification_sinks, [Harness.Test.CaptureSink])
    Application.put_env(:harness, :test_capture_pid, self())

    on_exit(fn ->
      Application.delete_env(:harness, :notification_sinks)
      Application.delete_env(:harness, :test_capture_pid)
    end)
  end

  @spec stage_origin_advancing_hook(String.t()) :: :ok
  defp stage_origin_advancing_hook(origin) do
    competitor = competing_commit(origin)
    hooks_dir = Path.join(origin, "hooks")
    File.mkdir_p!(hooks_dir)
    GitFixture.git!(origin, ["config", "core.hooksPath", hooks_dir])

    File.write!(Path.join(hooks_dir, "update"), """
    #!/bin/sh
    ref="$1"
    if [ "$ref" = "refs/heads/main" ]; then
      git update-ref refs/heads/main #{competitor}
      echo "remote advanced by hook"
      exit 1
    fi
    exit 0
    """)

    File.chmod!(Path.join(hooks_dir, "update"), @executable_file_mode)
    :ok
  end

  @spec competing_commit(String.t()) :: String.t()
  defp competing_commit(origin) do
    clone = Path.join(System.tmp_dir!(), "lander-compete-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(clone) end)

    {_out, 0} = System.cmd("git", ["clone", "-q", origin, clone], stderr_to_stdout: true)
    GitFixture.git!(clone, ["config", "user.email", "compete@example.com"])
    GitFixture.git!(clone, ["config", "user.name", "Competitor"])
    File.write!(Path.join(clone, "competing.txt"), "competing\n")
    GitFixture.git!(clone, ["add", "."])
    GitFixture.git!(clone, ["commit", "-q", "-m", "competing change"])
    GitFixture.git!(clone, ["push", "-q", "origin", "HEAD:refs/heads/hook-competing"])
    sha(clone, "HEAD")
  end

  @spec roadmap_markers() :: String.t()
  defp roadmap_markers, do: "# Roadmap\n\n<!-- TASKS:BEGIN phase=1 -->\n<!-- TASKS:END -->\n"

  @spec roadmap_toml(String.t(), String.t()) :: String.t()
  defp roadmap_toml(id, title) do
    """
    schema_version = 2
    project = "lander-roadmap"
    default_branch = "main"
    vision = "Fixture roadmap."

    [phases.1]
    name = "Fixture"
    order = 1
    status = "in_progress"

    [bundles.fixture]
    description = "Fixture"
    order = 1
    phase = 1

    #{task_toml(id, title)}
    """
  end

  @spec task_toml(String.t(), String.t()) :: String.t()
  defp task_toml(id, title) do
    """
    [[task]]
    id = "#{id}"
    phase = 1
    bundle = "fixture"
    status = "pending"
    title = "#{title}"
    scores = { d = 2, b = 5, u = 5 }
    body = "Body for #{title}."
    files_to_modify = ["lib/#{String.downcase(String.replace(title, " ", "_"))}.ex"]
    created_at = "2026-06-14"
    """
  end

  @spec render_roadmap!(String.t()) :: :ok
  defp render_roadmap!(repo) do
    {_output, 0} =
      System.cmd("rmap", ["render", "--tasks-path", Path.join(repo, "roadmap/tasks.toml")],
        cd: repo,
        stderr_to_stdout: true
      )

    :ok
  end

  @spec log_record(String.t()) :: LogRecord.t()
  defp log_record(run_id) do
    %LogRecord{
      batch_id: "batch-#{run_id}",
      run_id: run_id,
      task_id: "1",
      adapter: Claude,
      state: :done,
      reason: :approved,
      verdict: :approve,
      duration_ms: 1
    }
  end
end
