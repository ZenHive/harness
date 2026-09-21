defmodule Harness.Dashboard.QALiveTest do
  use Harness.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Harness.Audit.QA
  alias Harness.Audit.QAAttempt
  alias Harness.Audit.Requests
  alias Harness.Dashboard.QA, as: Presentation
  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry

  @endpoint Harness.Dashboard.Endpoint
  @moduletag :integration

  setup do
    %{repo: repo} = GitFixture.init_with_origin()
    project = %{ProjectFixture.from_repo(repo, target_branch: "main") | qa_command: "printf full-suite"}
    :ok = ProjectRegistry.register(project)
    on_exit(fn -> ProjectRegistry.unregister(project.name) end)

    oban = [
      name: Harness.Oban,
      repo: Repo,
      testing: :manual,
      queues: false,
      plugins: false,
      notifier: Oban.Notifiers.Isolated
    ]

    start_supervised!({Oban, oban})

    %{project: project, repo: repo, revision: sha(repo)}
  end

  test "overview loads, filters and links to bounded project history", ctx do
    attempt = record(ctx, "passed")
    {:ok, view, _} = live(build_conn(), "/harness/qa")
    html = render_async(view)
    assert html =~ "QA configured"
    assert html =~ ctx.project.name
    assert html =~ ctx.revision
    assert html =~ "Latest result: passed"
    assert html =~ "Latest evidence matches"
    refute html =~ "private transcript"

    view |> form("#qa-filters", %{project: ctx.project.name, status: "failed"}) |> render_change()
    assert render_async(view) =~ "No projects match"
    view |> form("#qa-filters", %{project: ctx.project.name, status: "passed"}) |> render_change()
    assert render_async(view) =~ ctx.project.name
    view |> element("#qa-project-#{ctx.project.name} h2 a") |> render_click()
    assert render_async(view) =~ "Recent attempts (up to 10)"
    assert has_element?(view, "#qa-attempt-#{attempt.id}")
    assert render(view) =~ "codex / test-model"
  end

  test "evidence is on demand, bounded and identifies missing check outcomes", ctx do
    attempt = record(ctx, "failed")
    {:ok, view, _} = live(build_conn(), "/harness/qa/#{ctx.project.name}")
    render_async(view)
    refute has_element?(view, "#qa-evidence")
    view |> element("#qa-attempt-#{attempt.id} button") |> render_click()
    html = render_async(view)
    assert html =~ "Per-check detail unavailable"
    assert html =~ "Suite failed: one regression"
    assert html =~ "Next evidence"
    refute html =~ "transcript-tail-marker"
    view |> element("button", "Next evidence") |> render_click()
    assert render_async(view) =~ "transcript-tail-marker"
    assert {:ok, page} = QA.evidence(attempt.id, 0, 64)
    assert String.length(page.evidence) == 64
    assert {:error, :not_found} = QA.detail("another-project", attempt.id)
    assert {:ok, %{evidence: ""}} = QA.evidence(attempt.id, 9_999_999_999)

    QA.pin(attempt, %{
      report: %{"qa" => %{"checks" => [%{"name" => "coverage", "status" => "incomplete", "reason" => "missing tool"}]}}
    })

    view |> element("#qa-attempt-#{attempt.id} button") |> render_click()
    html = render_async(view)
    assert html =~ "coverage"
    assert html =~ "missing tool"
    assert html =~ "incomplete"
  end

  test "start, duplicate submission, running and failed retry update without a reload", ctx do
    {:ok, view, _} = live(build_conn(), "/harness/qa/#{ctx.project.name}")
    render_async(view)
    view |> element("#qa-start") |> render_click()
    assert render_async(view) =~ "queued."
    view |> element("#qa-start") |> render_click()
    assert render_async(view) =~ "already active"
    jobs = from job in Oban.Job, where: job.args["project_name"] == ^ctx.project.name
    assert [job] = Repo.all(jobs)
    Repo.update!(Ecto.Changeset.change(job, state: "executing", attempt: 1))
    {:ok, attempt} = QA.start(%{project: ctx.project, base_sha: ctx.revision, job_id: job.id, attempt: 1})
    QA.pin(attempt, %{revision: ctx.revision})
    assert refresh(view) =~ "running"
    QA.pin(attempt, %{status: "failed"})
    Repo.update!(Ecto.Changeset.change(job, state: "completed"))
    assert refresh(view) =~ "Retry QA"
    view |> element("#qa-start") |> render_click()
    assert render_async(view) =~ "queued."
    assert Repo.aggregate(jobs, :count) == 2
    assert [%{status: "queued", latest: %{status: "failed"}}] = Presentation.page(ctx.project.name, "failed", 0).rows
  end

  test "active requests deduplicate but revision and command changes retain newer work", ctx do
    assert {:ok, first} = Requests.enqueue(ctx.project.name)
    assert {:ok, duplicate} = Requests.enqueue(ctx.project.name)
    assert first.id == duplicate.id
    assert duplicate.conflict?
    Repo.update!(Ecto.Changeset.change(first, state: "completed"))
    assert {:ok, recheck} = Requests.enqueue(ctx.project.name)
    refute recheck.id == first.id
    refute recheck.conflict?
    Repo.update!(Ecto.Changeset.change(recheck, state: "executing"))
    assert {:ok, still_active} = Requests.enqueue(ctx.project.name)
    assert still_active.id == recheck.id
    File.write!(Path.join(ctx.repo, "new.txt"), "new work")
    GitFixture.git!(ctx.repo, ["add", "new.txt"])
    GitFixture.git!(ctx.repo, ["commit", "-qm", "new work"])
    GitFixture.git!(ctx.repo, ["push", "-q", "origin", "main"])
    assert {:ok, newer} = Requests.enqueue(ctx.project.name)
    refute newer.id == recheck.id
    assert newer.args["qa_revision"] == sha(ctx.repo)
    :ok = ProjectRegistry.upsert(%{ctx.project | qa_command: "printf changed-suite"})
    assert {:ok, changed} = Requests.enqueue(ctx.project.name)
    refute changed.id in [first.id, recheck.id, newer.id]
    assert changed.args["qa_command"] == "printf changed-suite"
  end

  test "operator requests reuse queued audits and matching executing attempts", ctx do
    alias Harness.Audit.Worker

    args = %{"project_name" => ctx.project.name, "base_sha" => ctx.revision}
    {:ok, queued} = Oban.insert(Harness.Oban, Worker.new(args, unique: Worker.unique_opts()))
    assert {:ok, reused} = Requests.enqueue(ctx.project.name)
    assert reused.id == queued.id
    assert reused.conflict?

    Repo.update!(Ecto.Changeset.change(queued, state: "executing", attempt: 1))
    {:ok, attempt} = QA.start(%{project: ctx.project, base_sha: ctx.revision, job_id: queued.id, attempt: 1})
    QA.pin(attempt, %{revision: ctx.revision})
    assert {:ok, reused} = Requests.enqueue(ctx.project.name)
    assert reused.id == queued.id
    :ok = ProjectRegistry.upsert(%{ctx.project | qa_command: "printf different-suite"})
    assert {:ok, newer} = Requests.enqueue(ctx.project.name)
    refute newer.id == queued.id
    assert {:ok, %{pending: [%{status: "running"}, %{status: "queued"}]}} = QA.list(ctx.project.name, 1)
  end

  test "unavailable queue and target return explicit errors", ctx do
    stop_supervised!(Harness.Oban)
    assert {:error, {:queue_unavailable, _}} = Requests.enqueue(ctx.project.name)
    :ok = ProjectRegistry.upsert(%{ctx.project | target_branch: nil})
    assert {:error, :no_target_branch} = Requests.enqueue(ctx.project.name)
    :ok = ProjectRegistry.upsert(%{ctx.project | target_branch: "missing-target"})
    assert {:error, {:git_failed, _, _, _}} = Requests.enqueue(ctx.project.name)
  end

  test "concurrent requests on separate Postgres connections acknowledge the same durable job", ctx do
    alias Ecto.Adapters.SQL.Sandbox

    Sandbox.checkin(Repo)
    Sandbox.mode(Repo, :manual)

    try do
      jobs =
        1..6
        |> Task.async_stream(
          fn _ ->
            Sandbox.unboxed_run(Repo, fn -> Requests.enqueue(ctx.project.name) end)
          end,
          max_concurrency: 6
        )
        |> Enum.map(fn {:ok, {:ok, job}} -> job end)

      assert [id] = jobs |> Enum.map(& &1.id) |> Enum.uniq()
      assert is_integer(id)

      Sandbox.unboxed_run(Repo, fn ->
        assert Repo.aggregate(from(j in Oban.Job, where: j.args["project_name"] == ^ctx.project.name), :count) == 1
      end)
    after
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from(j in Oban.Job, where: j.args["project_name"] == ^ctx.project.name))
      end)
    end
  end

  test "rollout compares catalog commands and displays persisted settings plus landing overrides", ctx do
    alias Harness.Landing.Settings
    alias Harness.ProjectRegistry.Schema.Project, as: StoredProject
    alias Harness.Projects.DispatchQA.Catalog

    prior = Settings.overrides()

    on_exit(fn ->
      Harness.SettingsStore.put(:landing, prior)
      ProjectRegistry.refresh_landing_overrides()
      ProjectRegistry.unregister("harness")
    end)

    entry = Catalog.entry("harness")
    project = %{ctx.project | name: "harness", check_command: entry.dispatch, qa_command: entry.qa}
    Repo.insert!(%StoredProject{name: project.name, payload: :erlang.term_to_binary(project)})
    :ok = ProjectRegistry.register(project)
    :ok = Settings.set(project.name, :auto, "main", "test")
    {:ok, effective} = ProjectRegistry.lookup(project.name)
    row = Presentation.project(effective)
    assert row.adoption == "Focused dispatch command configured"
    assert row.override == %{landing_policy: :auto, target_branch: "main"}
    assert row.persisted.registered.landing_policy == :manual
    assert row.persisted.effective.landing_policy == :auto
    refute row.matched
    assert Presentation.project(%{effective | check_command: "mix precommit.full"}).adoption =~ "retained"
    {:ok, view, _} = live(build_conn(), "/harness/qa/harness")
    html = render_async(view)
    assert html =~ "Landing override"
    assert html =~ "Persisted registration"
    assert html =~ "No matching latest evidence"
  end

  test "command, target and revision drift never reuse historical success", ctx do
    record(ctx, "passed")
    assert Presentation.project(ctx.project).matched
    refute Presentation.project(%{ctx.project | qa_command: "another command"}).matched
    refute Presentation.project(%{ctx.project | target_branch: "other"}).matched
    File.write!(Path.join(ctx.repo, "new.txt"), "new work")
    GitFixture.git!(ctx.repo, ["add", "new.txt"])
    GitFixture.git!(ctx.repo, ["commit", "-qm", "new work"])
    GitFixture.git!(ctx.repo, ["push", "-q", "origin", "main"])
    refute Presentation.project(ctx.project).matched
    {:ok, view, _} = live(build_conn(), "/harness/qa/#{ctx.project.name}")
    assert render_async(view) =~ "Historical evidence: command, target or revision differs"
  end

  test "query and action errors are visible and can be retried", ctx do
    {:ok, view, _} = live(build_conn(), "/harness/qa/#{ctx.project.name}")
    render_async(view)
    :ok = ProjectRegistry.upsert(%{ctx.project | qa_command: nil})
    view |> element("#qa-start") |> render_click()
    assert render_async(view) =~ "QA request failed: :qa_not_configured"
    stop_supervised!(Repo)
    html = refresh(view)
    assert html =~ "QA facts unavailable"
    refute html =~ "No recorded QA attempts"
    assert has_element?(view, "button", "Retry loading")
    assert {:error, {:qa_unavailable, _}} = QA.list(ctx.project.name)
  end

  test "absent project and absent QA configuration have usable states", ctx do
    {:ok, missing, _} = live(build_conn(), "/harness/qa/missing-project")
    assert render_async(missing) =~ "QA facts unavailable"
    assert has_element?(missing, "button", "Retry loading")
    :ok = ProjectRegistry.upsert(%{ctx.project | qa_command: nil})
    {:ok, view, _} = live(build_conn(), "/harness/qa/#{ctx.project.name}")
    html = render_async(view)
    assert html =~ "QA not configured"
    refute html =~ "No matching latest evidence"
    refute html =~ "Rollout evidence"
    refute html =~ "No rollout mapping available"
    assert has_element?(view, "#qa-start[disabled]")
    assert {:error, :qa_not_configured} = Requests.enqueue(ctx.project.name)

    {:ok, overview, _} = live(build_conn(), "/harness/qa")
    overview_html = render_async(overview)
    assert overview_html =~ "QA not configured"
    refute overview_html =~ "No matching latest evidence"
    refute overview_html =~ "Rollout evidence"
  end

  test "history and evidence reads remain bounded", ctx do
    for _ <- 1..12, do: record(ctx, "incomplete")
    attempts = Presentation.project(ctx.project, 10).attempts
    assert Enum.count_until(attempts, 11) == 10
    assert {:ok, %{attempts: [summary]}} = QA.list(ctx.project.name, 1)
    refute Map.has_key?(summary, :report)
    refute Map.has_key?(summary, :transcript)
  end

  defp refresh(view) do
    # A completed queue action starts a separate facts read; settle it before the timer tick.
    render_async(view)
    send(view.pid, :refresh_qa)
    render_async(view)
  end

  defp record(ctx, status) do
    Repo.insert!(%QAAttempt{
      project_name: ctx.project.name,
      target_branch: "main",
      base_sha: ctx.revision,
      revision: ctx.revision,
      command: ctx.project.qa_command,
      status: status,
      agent: "codex",
      model: "test-model",
      report: %{"qa" => %{"report" => "Suite failed: one regression", "evidence" => "unit suite: exit 1"}},
      transcript: "private transcript" <> String.duplicate("x", 9_000) <> "transcript-tail-marker"
    })
  end

  defp sha(repo), do: repo |> GitFixture.git!(["rev-parse", "HEAD"]) |> String.trim()
end
