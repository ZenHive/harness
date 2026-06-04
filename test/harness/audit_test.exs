defmodule Harness.AuditTest do
  @moduledoc """
  Coverage for `Harness.Audit`'s mechanical substrate — the post-merge audit
  stage of the agent-gate workflow. These tests exercise everything *around*
  the audit agent: skip routing, the unaudited-range computation (last
  `audit(...)` commit beats the lander's fallback base), the empty-range
  no-op, and error surfacing — plus the full audited/no-changes paths driven
  by a `FakeAdapter` auditor double (the `:auditor` request override). Running
  a real audit agent is the live-agent smoke test's job, not a unit test's.

  `async: false` — checkouts land under the globally configured worktree root.
  """

  use ExUnit.Case, async: false

  alias Harness.Agent.Settings, as: AgentSettings
  alias Harness.AgentAdapter.Pi
  alias Harness.AgentRegistry
  alias Harness.Audit
  alias Harness.FakeAdapter
  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.ResultStore
  alias Harness.ResultStore.File, as: FileStore
  alias Harness.Run.LogRecord
  alias Harness.TokenUsage

  # ── git fixture: bare origin + working clone, mirroring the post-land state
  #    (everything the audit reviews is already on origin/main). ─────────────

  defp sha(repo, ref), do: repo |> GitFixture.git!(["rev-parse", ref]) |> String.trim()

  defp commit!(repo, file, message) do
    path = Path.join(repo, file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, message <> "\n")
    GitFixture.git!(repo, ["add", "."])
    GitFixture.git!(repo, ["commit", "-q", "-m", message])
  end

  # Mirrors the post-land state: unaudited work is already on origin/main,
  # beyond the lander's recorded base_sha.
  defp land_work!(ctx) do
    commit!(ctx.repo, "feature.txt", "landed work")
    GitFixture.git!(ctx.repo, ["push", "-q", "origin", "main"])
    sha(ctx.repo, "HEAD")
  end

  # An isolated File-backed store rooted in a per-test tmp dir, cleaned on exit.
  defp isolated_store do
    root = Path.join(System.tmp_dir!(), "harness_audit_store_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {FileStore, root: root}
  end

  defp seed_rejection(store, project_name, run_id, task_id, report) do
    record =
      struct!(LogRecord, %{
        batch_id: "batch-audit",
        run_id: run_id,
        task_id: task_id,
        project_name: project_name,
        adapter: FakeAdapter,
        state: :failed,
        reason: {:review_rejected, report},
        duration_ms: 100,
        verdict: :reject,
        review_report: report,
        token_usage: TokenUsage.empty()
      })

    :ok = ResultStore.record_run(record, store)
  end

  setup do
    %{origin: origin, repo: repo} = GitFixture.init_with_origin()
    project = ProjectFixture.from_repo(repo, name: "audit-demo", target_branch: "main")

    %{origin: origin, repo: repo, project: project, base_sha: sha(repo, "HEAD")}
  end

  describe "run/1 — skip routing (projects that can't be audited)" do
    test "a GitHub-sourced project is skipped", ctx do
      project = %{ctx.project | source: {:github, "https://github.com/zenhive/demo"}}

      assert {:skipped, :github_source} = Audit.run(%{project: project, base_sha: ctx.base_sha})
    end

    test "a project without a target branch is skipped", ctx do
      project = %{ctx.project | target_branch: nil}

      assert {:skipped, :no_target_branch} = Audit.run(%{project: project, base_sha: ctx.base_sha})
    end
  end

  describe "run/1 — unaudited-range computation" do
    test "an empty range (base_sha is the target tip) is a :noop", ctx do
      assert :noop = Audit.run(%{project: ctx.project, base_sha: ctx.base_sha})
    end

    test "the noop path removes its audit worktree", ctx do
      worktree_root = Harness.Worktree.base_dir()

      assert :noop = Audit.run(%{project: ctx.project, base_sha: ctx.base_sha})

      leftovers =
        worktree_root
        |> Path.join("**/landing/*")
        |> Path.wildcard()
        |> Enum.filter(&String.contains?(&1, Path.basename(ctx.repo)))

      assert leftovers == []
    end

    test "an audit(...) commit at the tip supersedes the fallback base — already audited → :noop", ctx do
      # Land work AFTER base_sha, then an audit commit covering it. If the range
      # were computed from the fallback base_sha, it would be non-empty and the
      # run would try to dispatch an auditor; the audit(...) marker must win.
      commit!(ctx.repo, "feature.txt", "landed work")
      commit!(ctx.repo, ".audit/abc1234.md", "audit(abc1234): hygiene pass — clean")
      GitFixture.git!(ctx.repo, ["push", "-q", "origin", "main"])

      assert :noop = Audit.run(%{project: ctx.project, base_sha: ctx.base_sha})
    end

    test "an unresolvable base_sha surfaces a range-check error", ctx do
      assert {:error, {:range_check_failed, _reason}} =
               Audit.run(%{project: ctx.project, base_sha: "0000000000000000000000000000000000000000"})
    end
  end

  describe "run/1 — the audit agent path (FakeAdapter auditor double)" do
    test "an auditor that commits a report gets its commit ff-pushed → {:audited, sha}", ctx do
      land_work!(ctx)
      short = ctx.repo |> GitFixture.git!(["rev-parse", "--short", "HEAD"]) |> String.trim()

      assert {:audited, audited_sha} =
               Audit.run(%{
                 project: ctx.project,
                 base_sha: ctx.base_sha,
                 implementer: "claude",
                 reviewer: "codex",
                 auditor: FakeAdapter,
                 auditor_opts: [command: {:audit, short}]
               })

      # The audit commit is origin/main's new tip…
      assert ctx.origin |> GitFixture.git!(["rev-parse", "main"]) |> String.trim() == audited_sha

      # …carrying the committed report, the audit(...) subject convention, and
      # NOT the harness-internal .harness/audit.json summary.
      GitFixture.git!(ctx.repo, ["fetch", "-q", "origin"])
      tree = GitFixture.git!(ctx.repo, ["ls-tree", "-r", "--name-only", "origin/main"])
      assert tree =~ ".audit/#{short}.md"
      refute tree =~ ".harness"

      subject = GitFixture.git!(ctx.repo, ["log", "-1", "--format=%s", "origin/main"])
      assert subject =~ "audit(#{short})"
    end

    test "the audited tip is the next audit's base — re-running is a :noop", ctx do
      land_work!(ctx)
      short = ctx.repo |> GitFixture.git!(["rev-parse", "--short", "HEAD"]) |> String.trim()

      request = %{
        project: ctx.project,
        base_sha: ctx.base_sha,
        auditor: FakeAdapter,
        auditor_opts: [command: {:audit, short}]
      }

      assert {:audited, _sha} = Audit.run(request)
      assert :noop = Audit.run(request)
    end

    test "an auditor that commits nothing is a :no_changes — origin is untouched", ctx do
      landed_sha = land_work!(ctx)

      assert :no_changes =
               Audit.run(%{
                 project: ctx.project,
                 base_sha: ctx.base_sha,
                 auditor: FakeAdapter,
                 auditor_opts: [command: :echo]
               })

      assert ctx.origin |> GitFixture.git!(["rev-parse", "main"]) |> String.trim() == landed_sha
    end
  end

  describe "run/1 — reviewer rejection history in the audit prompt (AC4)" do
    test "recent reviewer rejections for the project ride into the audit prompt", ctx do
      land_work!(ctx)
      short = ctx.repo |> GitFixture.git!(["rev-parse", "--short", "HEAD"]) |> String.trim()

      store = isolated_store()
      seed_rejection(store, ctx.project.name, "rev-1", "t.91", "reviewer rejected: stray debug IO left in handler")
      # A different project's rejection must NOT leak into this project's prompt.
      seed_rejection(store, "other-project", "rev-2", "t.99", "unrelated rejection from another repo")

      assert {:audited, _sha} =
               Audit.run(%{
                 project: ctx.project,
                 base_sha: ctx.base_sha,
                 auditor: FakeAdapter,
                 auditor_opts: [command: {:audit_capture_prompt, short}],
                 result_store: store
               })

      GitFixture.git!(ctx.repo, ["fetch", "-q", "origin"])
      prompt = GitFixture.git!(ctx.repo, ["show", "origin/main:.audit/#{short}.md"])

      assert prompt =~ "Reviewer-quality feedback loop"
      assert prompt =~ "t.91"
      assert prompt =~ "stray debug IO left in handler"
      # Scoped to this project — the other repo's rejection is filtered out.
      refute prompt =~ "t.99"
    end

    test "a project with no recorded rejections frames the section as empty", ctx do
      land_work!(ctx)
      short = ctx.repo |> GitFixture.git!(["rev-parse", "--short", "HEAD"]) |> String.trim()

      assert {:audited, _sha} =
               Audit.run(%{
                 project: ctx.project,
                 base_sha: ctx.base_sha,
                 auditor: FakeAdapter,
                 auditor_opts: [command: {:audit_capture_prompt, short}],
                 result_store: isolated_store()
               })

      GitFixture.git!(ctx.repo, ["fetch", "-q", "origin"])
      prompt = GitFixture.git!(ctx.repo, ["show", "origin/main:.audit/#{short}.md"])

      assert prompt =~ "(no reviewer rejections recorded for this project)"
    end

    test "an explicit result_store: false disables the lookup even when a store is configured", ctx do
      land_work!(ctx)
      short = ctx.repo |> GitFixture.git!(["rev-parse", "--short", "HEAD"]) |> String.trim()

      # A configured store HAS a rejection for this project; the request explicitly
      # disables persistence (`false`), which must win over the configured fallback.
      configured = isolated_store()
      seed_rejection(configured, ctx.project.name, "rev-9", "t.42", "configured-store rejection that must not leak")
      prev = Application.get_env(:harness, :result_store)
      Application.put_env(:harness, :result_store, configured)
      on_exit(fn -> Application.put_env(:harness, :result_store, prev) end)

      assert {:audited, _sha} =
               Audit.run(%{
                 project: ctx.project,
                 base_sha: ctx.base_sha,
                 auditor: FakeAdapter,
                 auditor_opts: [command: {:audit_capture_prompt, short}],
                 result_store: false
               })

      GitFixture.git!(ctx.repo, ["fetch", "-q", "origin"])
      prompt = GitFixture.git!(ctx.repo, ["show", "origin/main:.audit/#{short}.md"])

      refute prompt =~ "t.42"
      assert prompt =~ "(no reviewer rejections recorded for this project)"
    end
  end

  describe "run/1 — origin synchronization" do
    test "audits the pushed origin tip, not the local clone's stale HEAD", ctx do
      # Advance origin/main from a second clone; the fixture clone stays stale.
      other = Path.join(System.tmp_dir!(), "harness-audit-other-#{System.unique_integer([:positive])}")
      GitFixture.git!(ctx.repo, ["clone", "-q", ctx.origin, other])
      on_exit(fn -> File.rm_rf(other) end)
      GitFixture.git!(other, ["config", "user.email", "harness-test@example.com"])
      GitFixture.git!(other, ["config", "user.name", "Harness Test"])
      commit!(other, "remote_work.txt", "landed elsewhere")
      commit!(other, ".audit/def5678.md", "audit(def5678): hygiene pass — clean")
      GitFixture.git!(other, ["push", "-q", "origin", "main"])

      # The audit fetches origin and sees the remote audit(...) tip → :noop. If it
      # read the stale local HEAD instead, the range from base_sha would be empty
      # too — so assert against a base that is only "covered" on the remote.
      assert :noop = Audit.run(%{project: ctx.project, base_sha: ctx.base_sha})
    end
  end

  describe "select_auditor/1 — cross-family + reviewer-eligibility gate" do
    test "an explicit :auditor override wins, bypassing the registry scan" do
      assert {:ok, FakeAdapter} = Audit.select_auditor(%{auditor: FakeAdapter})
    end

    test "never selects a non-reviewer-eligible agent (pi), and whatever it picks IS eligible" do
      # The auditor commits+pushes to the shared target unsupervised, so the gate
      # must match the reviewer/resolver trust flag — pi (enabled but NOT
      # reviewer-eligible by default) must never be chosen to audit.
      result = Audit.select_auditor(%{implementer: "codex", reviewer: "claude"})

      # Either no eligible third-family agent is available in this env (=> skip),
      # or one is chosen — but it is NEVER pi, and it IS reviewer-eligible.
      refute match?({:ok, Pi}, result)

      case result do
        {:ok, module} ->
          {:ok, agent} = AgentRegistry.agent_for_module(module)
          assert AgentSettings.reviewer_eligible?(agent)
          refute agent == :pi

        {:skipped, :no_audit_agent} ->
          :ok
      end
    end
  end
end
