defmodule Harness.Roadmap.DurableTest do
  use ExUnit.Case, async: true

  alias Harness.GitFixture
  alias Harness.Project
  alias Harness.Roadmap
  alias Harness.Roadmap.Durable

  @moduletag :tmp_dir

  setup_all do
    if !System.find_executable("rmap") do
      flunk("""
      rmap CLI not found on PATH.

      Harness.Roadmap.Durable shells out to `rmap` — the roadmap substrate.
      Install it (a Rust binary, `cargo install` from the rmap repo) and ensure
      it is on PATH before running this suite.
      """)
    end

    :ok
  end

  # Two pending tasks on the seeded roadmap, so a transition on one and a
  # transition on the other prove neither clobbers the other's edit.
  @tasks_toml """
  schema_version = 2
  project = "durable-fixture"
  default_branch = "main"
  vision = "Durable roadmap write fixture."

  [phases.1]
  name = "Fixture Phase"
  order = 1
  status = "in_progress"

  [bundles.fixture]
  description = "Fixture bundle"
  order = 1
  phase = 1

  [[task]]
  id = "2"
  phase = 1
  bundle = "fixture"
  status = "pending"
  title = "First durable task"
  scores = { d = 2, b = 5, u = 5 }
  body = "First."
  created_at = "2026-06-05"

  [[task]]
  id = "3"
  phase = 1
  bundle = "fixture"
  status = "pending"
  title = "Second durable task"
  scores = { d = 2, b = 5, u = 5 }
  body = "Second."
  created_at = "2026-06-05"
  """

  setup do
    %{origin: origin, repo: repo} = GitFixture.init_with_origin()

    File.mkdir_p!(Path.join(repo, "roadmap"))
    File.write!(Path.join(repo, "roadmap/tasks.toml"), @tasks_toml)
    # rmap status re-renders ROADMAP.md + data.json on every transition and
    # reads the existing ROADMAP.md to byte-preserve prose around its marker
    # pairs, so seed a minimal one + render — mirroring a real project's layout.
    File.write!(Path.join(repo, "ROADMAP.md"), "# Roadmap\n\n<!-- TASKS:BEGIN phase=1 -->\n<!-- TASKS:END -->\n")

    {_out, 0} =
      System.cmd("rmap", ["render", "--tasks-path", Path.join(repo, "roadmap/tasks.toml")], stderr_to_stdout: true)

    GitFixture.git!(repo, ["add", "-A"])
    GitFixture.git!(repo, ["commit", "-q", "-m", "seed roadmap"])
    GitFixture.git!(repo, ["push", "-q", "origin", "main"])

    project = %Project{
      name: "durable-fixture",
      source: {:local, repo},
      roadmap_path: repo,
      languages: [:elixir],
      target_branch: "main"
    }

    %{origin: origin, repo: repo, project: project}
  end

  describe "durable transition through Roadmap.mark_*/2" do
    test "pushes the transition to the target branch as a durable commit", ctx do
      assert {:ok, _output} = Roadmap.mark_in_progress("2", project: ctx.project)

      assert origin_task_status(ctx.repo, "2") == "in_progress"
      assert origin_log(ctx.repo) =~ "roadmap: task 2 -> in_progress"
    end

    test "fast-forwards the operator's local checkout so tasks.toml stays in sync", ctx do
      # The operator clone is on the target branch with a clean tree, so the
      # post-push sync must advance its working copy — otherwise local tasks.toml
      # drifts behind origin and the operator's next merge breaks.
      assert String.trim(GitFixture.git!(ctx.repo, ["branch", "--show-current"])) == "main"

      assert {:ok, _output} = Roadmap.mark_in_progress("2", project: ctx.project)

      assert local_task_status(ctx.repo, "2") == "in_progress"
    end

    test "skips the local sync without clobbering a dirty operator checkout", ctx do
      File.write!(Path.join(ctx.repo, "scratch.txt"), "operator mid-edit\n")

      assert {:ok, _output} = Roadmap.mark_in_progress("2", project: ctx.project)

      # Pushed to origin, but the dirty local tree is left alone (not ff'd, not
      # clobbered) — the operator syncs manually once their tree is clean.
      assert origin_task_status(ctx.repo, "2") == "in_progress"
      assert local_task_status(ctx.repo, "2") == "pending"
      assert File.read!(Path.join(ctx.repo, "scratch.txt")) == "operator mid-edit\n"
    end

    test "interleaved transitions both land — neither clobbers the other's edit", ctx do
      assert {:ok, _output} = Roadmap.mark_in_progress("2", project: ctx.project)
      assert {:ok, _output} = Roadmap.mark_blocked("3", project: ctx.project, reason: "waiting on upstream")

      # The second transition fetched + rebased onto the first's commit, so both
      # survive on origin/main — the lost-write the durability fix prevents.
      assert origin_task_status(ctx.repo, "2") == "in_progress"
      assert origin_task_status(ctx.repo, "3") == "blocked"

      log = origin_log(ctx.repo)
      assert log =~ "roadmap: task 2 -> in_progress"
      assert log =~ "roadmap: task 3 -> blocked"
    end

    test "a no-op transition (already in that state) commits and pushes nothing", ctx do
      assert {:ok, _output} = Roadmap.mark_in_progress("2", project: ctx.project)
      tip_before = origin_tip(ctx.repo)

      # Re-marking the same status is an rmap no-op: no file change, so nothing
      # to commit or push — the target tip stays put.
      assert {:ok, _output} = Roadmap.mark_in_progress("2", project: ctx.project)
      assert origin_tip(ctx.repo) == tip_before
    end

    test "a project without a target_branch falls back to a local write, not a push", ctx do
      local = %{ctx.project | target_branch: nil}
      tip_before = origin_tip(ctx.repo)

      assert {:ok, _output} = Roadmap.mark_in_progress("2", project: local)

      # No push happened; the local on-disk copy was mutated instead.
      assert origin_tip(ctx.repo) == tip_before
      assert File.read!(Path.join(ctx.repo, "roadmap/tasks.toml")) =~ "in_progress"
    end
  end

  describe "Durable.commit/3 — non-ff retry" do
    test "re-fetches, replays the mutation, and retries instead of force-pushing", ctx do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      apply_fun = fn root ->
        attempt = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        # On the first attempt a competing writer lands first, so our ff-push is
        # rejected non-ff and the loop must re-fetch + replay onto its tip.
        if attempt == 0, do: competing_push(ctx.origin)
        rmap_status(root, ["2", "in_progress"])
      end

      assert {:ok, _output} =
               Durable.commit(ctx.repo, "main",
                 message: "roadmap: task 2 -> in_progress",
                 apply: apply_fun
               )

      # Replayed at least once (attempt 0 lost the race, attempt 1 won).
      assert Agent.get(counter, & &1) >= 2
      # Our transition landed AND the competitor's commit survived — proof the
      # retry rebased rather than force-pushing over the winner.
      assert origin_task_status(ctx.repo, "2") == "in_progress"
      assert origin_log(ctx.repo) =~ "competing change"
    end

    test "surfaces an error after exhausting the retry cap, never force-pushing", ctx do
      # Every attempt loses the race (a fresh competitor each time), so the push
      # is non-ff on every try and the cap is hit.
      apply_fun = fn root ->
        competing_push(ctx.origin)
        rmap_status(root, ["2", "in_progress"])
      end

      assert {:error, {:roadmap_push_exhausted, "main", 2}} =
               Durable.commit(ctx.repo, "main",
                 message: "roadmap: task 2 -> in_progress",
                 apply: apply_fun,
                 max_attempts: 2
               )
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  @spec rmap_status(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  defp rmap_status(root, status_args) do
    args = ["status" | status_args] ++ ["--tasks-path", Path.join(root, "roadmap/tasks.toml")]

    case System.cmd("rmap", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {code, output}}
    end
  end

  # A second clone of `origin` lands an unrelated commit on main first, forcing a
  # non-ff rejection for any writer that based its push on the prior tip.
  defp competing_push(origin) do
    clone = Path.join(System.tmp_dir!(), "durable-compete-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(clone) end)

    {_out, 0} = System.cmd("git", ["clone", "-q", origin, clone], stderr_to_stdout: true)
    GitFixture.git!(clone, ["config", "user.email", "compete@example.com"])
    GitFixture.git!(clone, ["config", "user.name", "Competitor"])
    File.write!(Path.join(clone, "competing-#{System.unique_integer([:positive])}.txt"), "x\n")
    GitFixture.git!(clone, ["add", "."])
    GitFixture.git!(clone, ["commit", "-q", "-m", "competing change"])
    GitFixture.git!(clone, ["push", "-q", "origin", "main"])
    :ok
  end

  # Reads task `id`'s status from roadmap/tasks.toml as it exists on origin/main,
  # via rmap so the assertion is contract-accurate rather than TOML-string-shaped.
  defp origin_task_status(repo, id) do
    toml = origin_show(repo, "roadmap/tasks.toml")
    path = Path.join(System.tmp_dir!(), "durable-verify-#{System.unique_integer([:positive])}.toml")
    File.write!(path, toml)
    on_exit(fn -> File.rm(path) end)

    {out, 0} = System.cmd("rmap", ["show", id, "--json", "--tasks-path", path], stderr_to_stdout: true)
    out |> JSON.decode!() |> Map.fetch!("status")
  end

  # Reads task `id`'s status from the operator clone's on-disk roadmap/tasks.toml
  # (the working copy), to assert the post-push local fast-forward landed.
  defp local_task_status(repo, id) do
    path = Path.join(repo, "roadmap/tasks.toml")
    {out, 0} = System.cmd("rmap", ["show", id, "--json", "--tasks-path", path], stderr_to_stdout: true)
    out |> JSON.decode!() |> Map.fetch!("status")
  end

  defp origin_show(repo, file) do
    GitFixture.git!(repo, ["fetch", "-q", "origin", "main"])
    GitFixture.git!(repo, ["show", "origin/main:#{file}"])
  end

  defp origin_log(repo) do
    GitFixture.git!(repo, ["fetch", "-q", "origin", "main"])
    GitFixture.git!(repo, ["log", "--format=%s", "origin/main"])
  end

  defp origin_tip(repo) do
    GitFixture.git!(repo, ["fetch", "-q", "origin", "main"])
    repo |> GitFixture.git!(["rev-parse", "origin/main"]) |> String.trim()
  end
end
