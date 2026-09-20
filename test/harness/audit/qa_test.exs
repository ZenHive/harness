defmodule Harness.Audit.QATest do
  use Harness.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox
  alias Harness.Audit
  alias Harness.Audit.QA
  alias Harness.Audit.QAAttempt
  alias Harness.Audit.Worker
  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry

  @endpoint Harness.Dashboard.Endpoint

  @moduletag :integration

  defmodule Auditor do
    @moduledoc false
    use Harness.AgentAdapter

    alias Harness.AgentAdapter.Testing.FakeAdapter

    @impl true
    defdelegate capabilities(), to: FakeAdapter
    @impl true
    defdelegate rule_channel(), to: FakeAdapter
    @impl true
    def build_command(invocation) do
      opts = invocation.adapter_opts
      Agent.update(opts[:capture], &Map.put(&1, :prompt, invocation.prompt))
      if opts[:on_invoke], do: opts[:on_invoke].()
      if opts[:in_worktree], do: opts[:in_worktree].(invocation.cwd)
      report = opts[:report] || %{}
      script = ~S(mkdir -p .harness; printf '%s' "$1" > .harness/audit.json)
      {:ok, {"/bin/sh", ["-c", script, "qa-test", Jason.encode!(report)], []}}
    end
  end

  setup do
    %{repo: repo} = GitFixture.init_with_origin()

    project = %{
      ProjectFixture.from_repo(repo, target_branch: "main", check_command: "FOCUSED_ONLY")
      | qa_command: "printf full-suite"
    }

    capture = start_supervised!({Agent, fn -> %{} end})
    %{repo: repo, project: project, base: sha(repo), capture: capture}
  end

  test "legacy projects keep focused check_command behavior without QA rows", ctx do
    project = %{ctx.project | qa_command: nil}
    land(ctx.repo, "legacy")

    assert :no_changes =
             Audit.run(%{
               project: project,
               base_sha: ctx.base,
               auditor: Auditor,
               result_store: false,
               auditor_opts: [capture: ctx.capture, report: %{"cold_check" => %{"passed" => true}}]
             })

    prompt = Agent.get(ctx.capture, & &1.prompt)
    assert prompt =~ "FOCUSED_ONLY"
    refute prompt =~ "FULL-PROJECT QA"
    assert {:ok, %{attempts: []}} = QA.list(project.name)
  end

  test "clean evidence survives cache reset and covers every coalesced landing", ctx do
    first = land(ctx.repo, "one")
    revision = land(ctx.repo, "two")
    assert :no_changes = run(ctx, report(ctx.project, revision, "passed"))
    prompt = Agent.get(ctx.capture, & &1.prompt)
    assert prompt =~ ctx.project.qa_command
    refute prompt =~ "FOCUSED_ONLY"
    assert prompt =~ revision
    Harness.SettingsStore.reset_cache()
    assert {:ok, %{attempts: [attempt]}} = QA.list(ctx.project.name)
    assert attempt.status == "passed"
    assert attempt.revision == revision
    assert attempt.included_landings == 2
    row = Repo.get!(QAAttempt, attempt.id)
    assert row.landing_shas == [first, revision]
    assert QA.base(row) == revision
    assert {:ok, %{evidence: evidence}} = QA.evidence(row.id)
    assert evidence =~ "full-suite"
    assert {:ok, %{evidence: slice}} = QA.evidence(row.id, 0, 12)
    assert String.length(slice) == 12
    assert {:error, :invalid_limit} = QA.list(ctx.project.name, 101)
    assert {:error, :invalid_limit} = QA.evidence(row.id, -1, 12)
    assert {:error, :not_found} = QA.evidence("invalid")
  end

  test "a land during QA receives a subsequent range", ctx do
    revision = land(ctx.repo, "one")
    on_invoke = fn -> land(ctx.repo, "two") end
    assert :no_changes = run(ctx, report(ctx.project, revision, "passed"), on_invoke: on_invoke)
    next = sha(ctx.repo)
    refute next == revision
    assert :no_changes = run(%{ctx | base: revision}, report(ctx.project, next, "passed"))
    assert {:ok, %{attempts: [second, first]}} = QA.list(ctx.project.name)
    assert first.revision == revision
    assert second.base_sha == revision
    assert second.revision == next
    assert second.included_landings == 1
  end

  test "failed and missing artifacts retain the oldest pending range", ctx do
    revision = land(ctx.repo, "one")
    assert :no_changes = run(ctx, report(ctx.project, revision, "failed"))
    next = land(ctx.repo, "two")
    assert {:error, {:qa_incomplete, _}} = run(%{ctx | base: revision}, %{})
    assert {:ok, %{attempts: [missing, failed]}} = QA.list(ctx.project.name)
    assert missing.status == "incomplete"
    assert failed.status == "failed"
    assert missing.base_sha == ctx.base
    assert :no_changes = run(%{ctx | base: revision}, report(ctx.project, next, "passed"))
    assert {:ok, %{attempts: [passed | _]}} = QA.list(ctx.project.name)
    assert passed.base_sha == ctx.base
    assert passed.included_landings == 2
  end

  test "incomplete QA publishes repair discoveries before requesting retry", ctx do
    revision = land(ctx.repo, "needs-credentials")

    discovery = fn path ->
      File.mkdir_p!(Path.join(path, "roadmap"))
      File.write!(Path.join(path, "roadmap/qa-repair.txt"), "Configure missing test credentials")
    end

    assert {:error, {:qa_incomplete, id}} =
             run(ctx, report(ctx.project, revision, "incomplete"), in_worktree: discovery)

    assert GitFixture.git!(ctx.repo, ["show", "origin/main:roadmap/qa-repair.txt"]) =~
             "Configure missing test credentials"

    attempt = Repo.get!(QAAttempt, id)
    assert attempt.status == "incomplete"
    assert attempt.report["qa"]["report"] == "clean hygiene"
    assert QA.base(attempt) == ctx.base
  end

  test "a rejected audit push retains the committed repair after worktree cleanup", ctx do
    revision = land(ctx.repo, "audited")

    discovery = fn path ->
      File.mkdir_p!(Path.join(path, "roadmap"))
      File.write!(Path.join(path, "roadmap/qa-repair.txt"), "retained repair")
    end

    assert {:push_rejected, _} =
             run(ctx, report(ctx.project, revision, "failed"),
               on_invoke: fn -> land(ctx.repo, "concurrent-land") end,
               in_worktree: discovery
             )

    [ref] =
      ctx.repo
      |> GitFixture.git!(["for-each-ref", "--format=%(refname)", "refs/heads/audit/recovery/"])
      |> String.split("\n", trim: true)

    assert GitFixture.git!(ctx.repo, ["show", ref <> ":roadmap/qa-repair.txt"]) == "retained repair"
  end

  test "incomplete evidence retains the actual driver termination", ctx do
    assert {:ok, attempt} = QA.start(%{project: ctx.project, base_sha: ctx.base})
    assert {:ok, saved} = QA.finish(attempt, %{}, {:timed_out, :idle}, "last tool call")
    assert saved.status == "incomplete"
    assert saved.report["termination"] == "{:timed_out, :idle}"
  end

  test "a newer executing job attempt cannot revive an interrupted QA attempt", ctx do
    job = Repo.insert!(Worker.new(%{"project_name" => ctx.project.name, "base_sha" => ctx.base}))
    Repo.update!(Ecto.Changeset.change(job, state: "executing", attempt: 1))
    assert {:ok, _} = QA.start(%{project: ctx.project, base_sha: ctx.base, job_id: job.id, attempt: 1})
    assert {:ok, %{attempts: [%{status: "running"}]}} = QA.list(ctx.project.name)

    Repo.update!(Ecto.Changeset.change(job, state: "executing", attempt: 2))
    assert {:ok, %{attempts: [%{status: "incomplete"}]}} = QA.list(ctx.project.name)
  end

  test "wrong revision, wrong command, missing evidence and interruptions never pass", ctx do
    revision = land(ctx.repo, "one")
    valid = report(ctx.project, revision, "passed")

    variants = [
      put_in(valid, ["qa", "revision"], "wrong"),
      put_in(valid, ["qa", "command"], "focused"),
      put_in(valid, ["qa", "evidence"], ""),
      put_in(valid, ["qa", "report"], nil),
      %{"qa" => nil}
    ]

    for invalid <- variants do
      assert {:error, {:qa_incomplete, _}} = run(ctx, invalid)
    end

    assert {:ok, attempt} = QA.start(%{project: ctx.project, base_sha: ctx.base})
    assert {:ok, attempt} = QA.pin(attempt, %{revision: revision})
    assert {:ok, %{status: "incomplete"}} = QA.finish(attempt, valid, {:timed_out, :total}, "interrupted")
    assert QA.base(attempt) == ctx.base
  end

  test "a reported command still matches after surrounding whitespace", ctx do
    revision = land(ctx.repo, "trim")
    valid = report(ctx.project, revision, "passed")
    padded = put_in(valid, ["qa", "command"], "  #{ctx.project.qa_command}  \n")

    assert :no_changes = run(ctx, padded)
    assert {:ok, %{attempts: [%{status: "passed"}]}} = QA.list(ctx.project.name)
  end

  test "an absent artifact cannot mark a clean agent exit as passed", ctx do
    land(ctx.repo, "missing-artifact")

    assert {:error, {:qa_incomplete, _}} =
             Audit.run(%{
               project: ctx.project,
               base_sha: ctx.base,
               auditor: Harness.Test.IdentityFakeAdapter,
               auditor_opts: [command: :echo],
               result_store: false
             })

    assert {:ok, %{attempts: [%{status: "incomplete"}]}} = QA.list(ctx.project.name)
  end

  test "explicit QA can recheck a passed unchanged revision", ctx do
    revision = land(ctx.repo, "unchanged")
    assert :no_changes = run(ctx, report(ctx.project, revision, "passed"))
    assert :no_changes = run(ctx, report(ctx.project, revision, "passed"))
    assert {:ok, %{attempts: [latest, prior]}} = QA.list(ctx.project.name)
    assert latest.status == "passed"
    assert latest.revision == prior.revision
    assert latest.base_sha == revision
    assert latest.included_landings == 0
  end

  test "retry marks the interrupted attempt incomplete and duplicate attempts preserve evidence", ctx do
    request = %{project: ctx.project, base_sha: ctx.base, job_id: 900_447, attempt: 1}
    assert {:ok, interrupted} = QA.start(request)
    assert {:ok, %{attempts: [%{status: "incomplete"}]}} = QA.list(ctx.project.name)
    assert {:ok, retried} = QA.start(%{request | attempt: 2})
    assert Repo.get!(QAAttempt, interrupted.id).status == "incomplete"
    assert {:error, %Ecto.Changeset{}} = QA.start(%{request | attempt: 2})
    assert QA.base(retried) == ctx.base
    assert Repo.aggregate(QAAttempt, :count) == 2
  end

  test "pending work survives a repository process restart", ctx do
    request = %{project: ctx.project, base_sha: ctx.base, job_id: 901_447, attempt: 1}
    assert {:ok, original} = Sandbox.unboxed_run(Repo, fn -> QA.start(request) end)
    stop_supervised!(Repo)
    start_supervised!(Repo)
    assert :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})
    assert Repo.get!(QAAttempt, original.id).base_sha == ctx.base
    assert {:ok, %{attempts: [%{status: "incomplete"}]}} = QA.list(ctx.project.name)
    assert {:ok, retried} = QA.start(%{request | attempt: 2})
    assert QA.base(retried) == ctx.base
    Sandbox.checkin(Repo)
    # The committed restart witness is owned by this test; remove it outside the sandbox.
    Sandbox.unboxed_run(Repo, fn -> Repo.delete_all(from(a in QAAttempt, where: a.id == ^original.id)) end)
  end

  test "waiting jobs coalesce but lands during execution retain a separate pending job", ctx do
    start_supervised!(
      {Oban,
       name: __MODULE__.Oban,
       repo: Repo,
       testing: :manual,
       queues: false,
       plugins: false,
       notifier: Oban.Notifiers.Isolated}
    )

    args = %{"project_name" => ctx.project.name, "base_sha" => ctx.base}
    changeset = Worker.new(args, unique: Worker.unique_opts())
    assert {:ok, first} = Oban.insert(__MODULE__.Oban, changeset)
    assert {:ok, duplicate} = Oban.insert(__MODULE__.Oban, changeset)
    assert first.id == duplicate.id
    assert {:ok, %{pending: [%{status: "queued"}]}} = QA.list(ctx.project.name)
    Repo.update!(Ecto.Changeset.change(first, state: "executing", attempt: 1))
    assert {:ok, attempt} = QA.start(%{project: ctx.project, base_sha: ctx.base, job_id: first.id, attempt: 1})
    assert {:ok, %{attempts: [%{status: "running"}]}} = QA.list(ctx.project.name)
    assert {:ok, %{status: "incomplete"}} = QA.incomplete(attempt, :unavailable_prerequisite)
    assert {:ok, subsequent} = Oban.insert(__MODULE__.Oban, changeset)
    refute subsequent.id == first.id
    assert {:ok, %{pending: [%{status: "running"}, %{status: "queued"}]}} = QA.list(ctx.project.name)
  end

  test "dashboard and driver expose durable QA facts and evidence", ctx do
    revision = land(ctx.repo, "dashboard")
    assert :no_changes = run(ctx, report(ctx.project, revision, "failed"))
    assert :ok = ProjectRegistry.register(ctx.project)
    on_exit(fn -> ProjectRegistry.unregister(ctx.project.name) end)
    assert {:ok, %{attempts: [attempt]}} = Harness.Dispatch.qa_status(ctx.project.name, 1)
    assert {:ok, %{evidence: evidence}} = Harness.Dispatch.qa_evidence(attempt.id, 0, 1000)
    assert evidence =~ "clean hygiene"
    assert {:ok, view, html} = live(build_conn(), "/harness/settings")
    assert has_element?(view, "#qa-status-#{ctx.project.name}")
    assert html =~ "QA failed"
    assert html =~ revision
    assert html =~ "clean hygiene"
    assert html =~ "Included commits: 1"
  end

  defp run(ctx, report, opts \\ []) do
    Audit.run(%{
      project: ctx.project,
      base_sha: ctx.base,
      auditor: Auditor,
      result_store: false,
      auditor_opts: [capture: ctx.capture, report: report] ++ opts
    })
  end

  defp report(project, revision, status) do
    %{
      "qa" => %{
        "revision" => revision,
        "command" => project.qa_command,
        "status" => status,
        "evidence" => "printf full-suite: full-suite; exit status 0",
        "report" => "clean hygiene"
      }
    }
  end

  defp sha(repo), do: repo |> GitFixture.git!(["rev-parse", "HEAD"]) |> String.trim()

  defp land(repo, filename) do
    File.write!(Path.join(repo, filename), filename)
    GitFixture.git!(repo, ["add", filename])
    GitFixture.git!(repo, ["commit", "-qm", filename])
    GitFixture.git!(repo, ["push", "-q", "origin", "main"])
    sha(repo)
  end
end
