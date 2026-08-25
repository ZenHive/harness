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

  # async: false because tests mutate global app env seams such as :rmap_path_dirs.
  use ExUnit.Case, async: false

  alias Harness.Agent.Settings, as: AgentSettings
  alias Harness.AgentAdapter.Pi
  alias Harness.AgentRegistry
  alias Harness.Audit
  alias Harness.Dashboard.OpsFeed
  alias Harness.Dashboard.OpsFeed.Op
  alias Harness.GitFixture
  # ── git fixture: bare origin + working clone, mirroring the post-land state
  #    (everything the audit reviews is already on origin/main). ─────────────
  alias Harness.Notification.Event
  alias Harness.ProjectFixture
  alias Harness.ResultStore
  alias Harness.ResultStore.Memory, as: MemoryStore
  alias Harness.Run.LogRecord
  alias Harness.SettingsStore
  alias Harness.Test.CaptureSink
  alias Harness.Test.IdentityFakeAdapter, as: FakeAdapter
  alias Harness.Test.SettingsStoreMemory
  alias Harness.TokenUsage

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

  # An isolated Memory-backed store rooted in a per-test scope, cleaned on exit.
  defp isolated_store do
    root = Path.join(System.tmp_dir!(), "harness_audit_store_#{System.unique_integer([:positive])}")
    on_exit(fn -> MemoryStore.reset(root: root) end)
    {MemoryStore, root: root}
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

  defp fake_rmap_dir do
    dir = Path.join(System.tmp_dir!(), "harness-audit-fake-rmap-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    path = Path.join(dir, "rmap")
    File.write!(path, "#!/bin/sh\necho fake-rmap\n")
    File.chmod!(path, 0o755)
    dir
  end

  defp with_rmap_path_dirs(dirs) do
    prior = Application.get_env(:harness, :rmap_path_dirs)
    Application.put_env(:harness, :rmap_path_dirs, dirs)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:harness, :rmap_path_dirs, prior),
        else: Application.delete_env(:harness, :rmap_path_dirs)
    end)
  end

  defp with_path(path) do
    prior = System.get_env("PATH", "")
    System.put_env("PATH", path)
    on_exit(fn -> System.put_env("PATH", prior) end)
  end

  defp fake_blocking_rmap_dir(log_path) do
    dir = Path.join(System.tmp_dir!(), "harness-audit-block-rmap-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    path = Path.join(dir, "rmap")

    File.write!(path, """
    #!/bin/sh
    printf 'ARGS:%s\\n' "$*" >> "#{log_path}"
    tasks_path=''
    previous=''
    for argument in "$@"; do
      if [ "$previous" = "--tasks-path" ]; then tasks_path="$argument"; fi
      previous="$argument"
    done
    if [ "$1" = "new" ]; then
      fragment=$(cat)
      printf '%s' "$fragment" >> "#{log_path}"
      printf '\\nEND_NEW\\n' >> "#{log_path}"
      printf '\\n%s\\n' "$fragment" >> "$tasks_path"
      echo "created task 77"
      exit 0
    fi
    if [ "$1" = "status" ]; then
      printf '\\n# status blocked\\n' >> "$tasks_path"
      echo "blocked"
      exit 0
    fi
    echo "unexpected rmap args: $*" >&2
    exit 64
    """)

    File.chmod!(path, 0o755)
    dir
  end

  defp seed_landed_record(store, ctx, run_id, task_id, landed_sha, opts \\ []) do
    record =
      struct!(LogRecord, %{
        batch_id: "batch-audit",
        run_id: run_id,
        task_id: task_id,
        project_name: ctx.project.name,
        adapter: FakeAdapter,
        state: :done,
        reason: :approved,
        duration_ms: 100,
        verdict: :approve,
        landed_sha: landed_sha,
        reviewer_adapter: Keyword.get(opts, :reviewer_adapter),
        reviewer_model: Keyword.get(opts, :reviewer_model),
        review_facets: Keyword.get(opts, :review_facets, %{}),
        domains: Keyword.get(opts, :domains, []),
        agent_output: "implementer transcript",
        reviewer_output: "reviewer transcript",
        token_usage: TokenUsage.empty()
      })

    :ok = ResultStore.record_run(record, store)
  end

  setup do
    %{origin: origin, repo: repo} = GitFixture.init_with_origin()
    commit!(repo, "roadmap/tasks.toml", "# audit fixture tasks")
    GitFixture.git!(repo, ["push", "-q", "origin", "main"])
    project = ProjectFixture.from_repo(repo, name: "audit-demo", target_branch: "main")
    prior_repo_enabled = Application.get_env(:harness, :repo_enabled)
    prior_settings_store = Application.get_env(:harness, :settings_store)
    Application.put_env(:harness, :repo_enabled, true)
    SettingsStoreMemory.reset(scope: :test_default)

    on_exit(fn ->
      restore(:repo_enabled, prior_repo_enabled)
      # The "repo_enabled false" test deletes :settings_store to exercise the
      # ephemeral store; restore it here so the deletion can't leak past this
      # module and silently flip every later settings read to the no-op store.
      restore(:settings_store, prior_settings_store)
      SettingsStoreMemory.reset(scope: :test_default)
    end)

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

      # Task 243: the audit broadcasts its lifecycle on the dashboard ops feed —
      # started when the auditor is selected, settled (stage :fixed) with the
      # agent transcript when the commit lands. Run the audit in a Task so its
      # port-receive loop runs there, not in this (subscribed) process — mirrors
      # production, where the Oban worker runs the agent and the LiveView subscribes.
      :ok = OpsFeed.subscribe()

      task =
        Task.async(fn ->
          Audit.run(%{
            project: ctx.project,
            base_sha: ctx.base_sha,
            implementer: "claude",
            reviewer: "codex",
            auditor: FakeAdapter,
            auditor_opts: [command: {:audit, short}]
          })
        end)

      assert {:audited, audited_sha} = Task.await(task, 30_000)

      assert_receive {:harness_op, %Op{kind: :audit, stage: :started, project: "audit-demo", agent: agent}}
      assert agent =~ "FakeAdapter"
      assert_receive {:harness_op, %Op{kind: :audit, stage: :fixed, sha: ^audited_sha, transcript: t}}
      assert is_binary(t)

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

    test "an auditor discovery reaches the target without dirtying the source checkout", ctx do
      land_work!(ctx)
      short = ctx.repo |> GitFixture.git!(["rev-parse", "--short", "HEAD"]) |> String.trim()
      rmap_log = Path.join(System.tmp_dir!(), "harness-audit-discovery-#{System.unique_integer([:positive])}.log")
      rmap_dir = fake_blocking_rmap_dir(rmap_log)
      with_path("#{rmap_dir}:#{System.get_env("PATH", "")}")
      before_status = GitFixture.git!(ctx.repo, ["status", "--porcelain"])

      assert {:audited, _sha} =
               Audit.run(%{
                 project: ctx.project,
                 base_sha: ctx.base_sha,
                 auditor: FakeAdapter,
                 auditor_opts: [command: {:audit_file_discovery, short}]
               })

      assert GitFixture.git!(ctx.repo, ["status", "--porcelain"]) == before_status
      GitFixture.git!(ctx.repo, ["fetch", "-q", "origin"])
      tasks = GitFixture.git!(ctx.repo, ["show", "origin/main:roadmap/tasks.toml"])
      assert tasks =~ "Audit discovery"
      refute File.read!(rmap_log) =~ Path.join(ctx.repo, "roadmap/tasks.toml")
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

    test "a red cold-check fact files a blocked rmap task, notifies, and pushes the filing without dirtying the source",
         ctx do
      landed_sha = land_work!(ctx)
      short = ctx.repo |> GitFixture.git!(["rev-parse", "--short", "HEAD"]) |> String.trim()
      File.mkdir_p!(Path.join(ctx.repo, "_build"))

      store = isolated_store()

      seed_landed_record(store, ctx, "run-cold", "224", landed_sha,
        reviewer_adapter: FakeAdapter,
        reviewer_model: "gpt-5.5-review",
        review_facets: %{"surface" => "otp"},
        domains: [:otp]
      )

      rmap_log = Path.join(System.tmp_dir!(), "harness-audit-rmap-#{System.unique_integer([:positive])}.log")
      rmap_dir = fake_blocking_rmap_dir(rmap_log)
      with_path("#{rmap_dir}:#{System.get_env("PATH", "")}")

      Application.put_env(:harness, :notification_sinks, [CaptureSink])
      Application.put_env(:harness, :test_capture_pid, self())

      on_exit(fn ->
        Application.delete_env(:harness, :notification_sinks)
        Application.delete_env(:harness, :test_capture_pid)
      end)

      before_status = GitFixture.git!(ctx.repo, ["status", "--porcelain"])

      assert {:audited, audited_sha} =
               Audit.run(%{
                 project: ctx.project,
                 base_sha: ctx.base_sha,
                 auditor: FakeAdapter,
                 auditor_opts: [command: {:audit_cold_check_by_warm_marker, short}],
                 result_store: store
               })

      assert_receive {:notify, %Event{type: :blocked, task_id: "77", project: "audit-demo", outcome: reason}}
      assert reason =~ landed_sha
      assert reason =~ "mix compile failed cold: :nofile"

      assert ctx.origin |> GitFixture.git!(["rev-parse", "main"]) |> String.trim() == audited_sha
      assert GitFixture.git!(ctx.repo, ["status", "--porcelain"]) == before_status
      GitFixture.git!(ctx.repo, ["fetch", "-q", "origin"])
      tasks = GitFixture.git!(ctx.repo, ["show", "origin/main:roadmap/tasks.toml"])
      assert tasks =~ "landed SHA #{landed_sha}"
      assert tasks =~ "# status blocked"
      subject = ctx.repo |> GitFixture.git!(["log", "-1", "--format=%s", "origin/main"]) |> String.trim()
      assert subject =~ ~r/^audit\(#{short}\): file cold-check discovery$/
      refute File.read!(rmap_log) =~ Path.join(ctx.repo, "roadmap/tasks.toml")

      assert {:ok, [record]} = ResultStore.list_run_records(store, run_id: "run-cold")

      assert Map.fetch!(record, :cold_check) == %{
               "passed" => false,
               "command" => "mix precommit",
               "tail" => "mix compile failed cold: :nofile"
             }

      assert record.approved_then_found_red == %{
               "reviewer_adapter" => Atom.to_string(FakeAdapter),
               "reviewer_agent" => nil,
               "reviewer_model" => "gpt-5.5-review",
               "review_facets" => %{"surface" => "otp"},
               "domains" => ["otp"],
               "cold_check" => %{
                 "passed" => false,
                 "command" => "mix precommit",
                 "tail" => "mix compile failed cold: :nofile"
               }
             }

      assert record.agent_output == "implementer transcript"
      assert record.reviewer_output == "reviewer transcript"

      rmap_calls = File.read!(rmap_log)
      assert rmap_calls =~ "ARGS:new --from-stdin"
      assert rmap_calls =~ "landed SHA #{landed_sha}"
      assert rmap_calls =~ "mix compile failed cold: :nofile"
      assert rmap_calls =~ "ARGS:status 77 blocked --reason"
    end

    test "a roadmap_path outside the source repo still files inside the audit worktree", ctx do
      landed_sha = land_work!(ctx)
      short = ctx.repo |> GitFixture.git!(["rev-parse", "--short", "HEAD"]) |> String.trim()
      File.mkdir_p!(Path.join(ctx.repo, "_build"))

      outside = Path.join(System.tmp_dir!(), "harness-audit-outside-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(outside, "roadmap"))
      outsider_tasks = Path.join(outside, "roadmap/tasks.toml")
      File.write!(outsider_tasks, "# outsider\n")
      on_exit(fn -> File.rm_rf(outside) end)

      rmap_log = Path.join(System.tmp_dir!(), "harness-audit-outside-rmap-#{System.unique_integer([:positive])}.log")
      rmap_dir = fake_blocking_rmap_dir(rmap_log)
      with_path("#{rmap_dir}:#{System.get_env("PATH", "")}")

      before_status = GitFixture.git!(ctx.repo, ["status", "--porcelain"])
      before_outsider = File.read!(outsider_tasks)

      assert {:audited, _sha} =
               Audit.run(%{
                 project: %{ctx.project | roadmap_path: outside},
                 base_sha: ctx.base_sha,
                 auditor: FakeAdapter,
                 auditor_opts: [command: {:audit_cold_check_by_warm_marker, short}]
               })

      assert GitFixture.git!(ctx.repo, ["status", "--porcelain"]) == before_status
      assert File.read!(outsider_tasks) == before_outsider
      refute File.read!(rmap_log) =~ outsider_tasks
      GitFixture.git!(ctx.repo, ["fetch", "-q", "origin"])
      tasks = GitFixture.git!(ctx.repo, ["show", "origin/main:roadmap/tasks.toml"])
      assert tasks =~ "landed SHA #{landed_sha}"
    end

    test "a green cold-check fact is persisted silently", ctx do
      landed_sha = land_work!(ctx)
      short = ctx.repo |> GitFixture.git!(["rev-parse", "--short", "HEAD"]) |> String.trim()

      store = isolated_store()
      seed_landed_record(store, ctx, "run-cold-green", "225", landed_sha)

      Application.put_env(:harness, :notification_sinks, [CaptureSink])
      Application.put_env(:harness, :test_capture_pid, self())

      on_exit(fn ->
        Application.delete_env(:harness, :notification_sinks)
        Application.delete_env(:harness, :test_capture_pid)
      end)

      assert :no_changes =
               Audit.run(%{
                 project: ctx.project,
                 base_sha: ctx.base_sha,
                 auditor: FakeAdapter,
                 auditor_opts: [command: {:audit_cold_check_green, short}],
                 result_store: store
               })

      refute_receive {:notify, %Event{type: :blocked}}, 100

      assert {:ok, [record]} = ResultStore.list_run_records(store, run_id: "run-cold-green")
      assert Map.fetch!(record, :cold_check) == %{"passed" => true, "command" => "mix precommit", "tail" => ""}
    end

    test "repo_enabled false leaves clean audit watermarks ephemeral", ctx do
      Application.put_env(:harness, :repo_enabled, false)
      Application.delete_env(:harness, :settings_store)
      landed_sha = land_work!(ctx)

      assert :no_changes =
               Audit.run(%{
                 project: ctx.project,
                 base_sha: ctx.base_sha,
                 auditor: FakeAdapter,
                 auditor_opts: [command: :echo]
               })

      assert ctx.origin |> GitFixture.git!(["rev-parse", "main"]) |> String.trim() == landed_sha
      assert :not_found = SettingsStore.fetch(:audit)
    end

    test "a clean audit watermark prevents re-auditing the same range after a later land", ctx do
      land_work!(ctx)
      first_short = ctx.repo |> GitFixture.git!(["rev-parse", "--short", "HEAD"]) |> String.trim()

      assert {:audited, audited_sha} =
               Audit.run(%{
                 project: ctx.project,
                 base_sha: ctx.base_sha,
                 auditor: FakeAdapter,
                 auditor_opts: [command: {:audit, first_short}]
               })

      assert stored_watermark(ctx) == audited_sha

      GitFixture.git!(ctx.repo, ["pull", "--ff-only", "-q", "origin", "main"])
      commit!(ctx.repo, "clean.txt", "clean landed work")
      GitFixture.git!(ctx.repo, ["push", "-q", "origin", "main"])
      clean_sha = sha(ctx.repo, "HEAD")

      assert :no_changes =
               Audit.run(%{
                 project: ctx.project,
                 base_sha: audited_sha,
                 auditor: FakeAdapter,
                 auditor_opts: [command: :echo]
               })

      assert stored_watermark(ctx) == clean_sha

      commit!(ctx.repo, "later.txt", "later landed work")
      GitFixture.git!(ctx.repo, ["push", "-q", "origin", "main"])
      later_short = ctx.repo |> GitFixture.git!(["rev-parse", "--short", "HEAD"]) |> String.trim()

      assert {:audited, _sha} =
               Audit.run(%{
                 project: ctx.project,
                 base_sha: clean_sha,
                 auditor: FakeAdapter,
                 auditor_opts: [command: {:audit_capture_prompt, later_short}]
               })

      GitFixture.git!(ctx.repo, ["fetch", "-q", "origin"])
      prompt = GitFixture.git!(ctx.repo, ["show", "origin/main:.audit/#{later_short}.md"])

      assert prompt =~ "later landed work"
      refute prompt =~ "clean landed work"
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

    test "discovery filing instructions ride into the audit prompt", ctx do
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

      assert prompt =~ "Discovery filing"
      assert prompt =~ "rmap new --from-stdin"
      assert prompt =~ "--tasks-path"
      assert prompt =~ "roadmap/tasks.toml"
      refute prompt =~ ctx.project.roadmap_path
      assert prompt =~ "FILE it as a real rmap task"
      assert prompt =~ "name the filed task id"
      assert prompt =~ "Do not leave TODO"
      assert prompt =~ "Harness does not decide what counts as a discovery"
      assert prompt =~ "Cold-build witness"
      assert prompt =~ "intentionally UN-warmed"
      assert prompt =~ "`cold_check`: {\"passed\": true|false"
      assert prompt =~ "Harness never runs this build itself"
    end

    test "makes rmap reachable inside the detached audit worktree even when PATH is scrubbed", ctx do
      land_work!(ctx)
      short = ctx.repo |> GitFixture.git!(["rev-parse", "--short", "HEAD"]) |> String.trim()
      rmap_dir = fake_rmap_dir()

      with_rmap_path_dirs([rmap_dir])
      with_path("/usr/bin:/bin")

      assert {:audited, _sha} =
               Audit.run(%{
                 project: ctx.project,
                 base_sha: ctx.base_sha,
                 auditor: FakeAdapter,
                 auditor_opts: [command: {:audit_capture_rmap_path, short}]
               })

      GitFixture.git!(ctx.repo, ["fetch", "-q", "origin"])
      captured = GitFixture.git!(ctx.repo, ["show", "origin/main:.audit/#{short}.md"])

      assert String.trim(captured) == Path.join(rmap_dir, "rmap")
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

  @spec restore(atom(), term()) :: :ok
  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)

  defp stored_watermark(ctx) do
    assert {:ok, watermarks} = SettingsStore.fetch(:audit)
    get_in(watermarks, [ctx.project.name, ctx.project.target_branch])
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

    test "excludes the implementer/reviewer family whether args are atoms or strings" do
      # Regression: exclusion is `to_string(agent) in excluded`, so atom-keyed
      # callers must be normalized too — otherwise the reviewer's own family
      # (cursor here) slips past the reject and audits its own land.
      string_req = Audit.select_auditor(%{implementer: "codex", reviewer: "cursor"})
      atom_req = Audit.select_auditor(%{implementer: :codex, reviewer: :cursor})

      assert string_req == atom_req

      for result <- [string_req, atom_req] do
        case result do
          {:ok, module} ->
            {:ok, agent} = AgentRegistry.agent_for_module(module)
            refute agent in [:codex, :cursor]

          {:skipped, :no_audit_agent} ->
            :ok
        end
      end
    end
  end

  describe "auditor_model/1 — model resolution for the audit invocation" do
    test "resolves the chosen auditor agent's configured {:agent_model, agent} default" do
      # Regression: the audit Invocation must thread a model, or a model-capable
      # auditor (codex/claude/...) trips AgentAdapter.invoke/2's {:model_required}
      # guard and every post-merge audit errors out.
      Application.put_env(:harness, :agent_model, codex: "gpt-5.5")
      on_exit(fn -> Application.delete_env(:harness, :agent_model) end)

      assert Audit.auditor_model(Harness.AgentAdapter.Codex) == "gpt-5.5"
    end

    test "yields nil for a module the registry can't reverse-map (test double)" do
      # FakeAdapter isn't a registered real adapter, so it has no agent to look up
      # a model for — and it's model-incapable, so invoke/2 accepts the nil.
      assert Audit.auditor_model(FakeAdapter) == nil
    end
  end
end
