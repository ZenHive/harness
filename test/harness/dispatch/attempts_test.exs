defmodule Harness.Dispatch.AttemptsTest do
  use ExUnit.Case, async: false

  alias Harness.Dispatch.Attempts
  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.ResultStore
  alias Harness.ResultStore.Memory
  alias Harness.Roadmap
  alias Harness.Run.LogRecord

  setup do
    previous = Application.get_env(:harness, :result_store)
    scope = {:attempts, System.unique_integer([:positive])}
    Application.put_env(:harness, :result_store, {Memory, scope: scope})
    on_exit(fn -> Application.put_env(:harness, :result_store, previous) end)
    %{repo: repo} = GitFixture.init_with_origin()
    project = ProjectFixture.from_repo(repo, name: "attempts", target_branch: "main")
    %{repo: repo, project: project}
  end

  test "history is project/task scoped and retains raw reviewer evidence and content identity", %{
    repo: repo,
    project: project
  } do
    task = %{"id" => "1", "title" => "Repair", "body" => "original"}
    fingerprint = Roadmap.task_fingerprint(task)
    GitFixture.git!(repo, ["checkout", "-b", "harness/prior"])
    File.write!(Path.join(repo, "delivery"), "retained")
    GitFixture.git!(repo, ["add", "delivery"])
    GitFixture.git!(repo, ["commit", "-m", "delivery"])
    sha = repo |> GitFixture.git!(["rev-parse", "HEAD"]) |> String.trim()
    report = "Exact report\nwith details\n"
    record = record("prior", fingerprint, report)
    :ok = ResultStore.record_run(record)
    :ok = ResultStore.record_run(%{record | run_id: "foreign", project_name: "another"})
    :ok = ResultStore.record_run(%{record | run_id: "other-task", task_id: "2", task_ids: ["2"]})

    assert {:ok, [enriched]} = Attempts.attach(project, [task])
    assert enriched["task_fingerprint"] == fingerprint
    assert [%{"run_id" => "prior", "review_report" => ^report, "git" => git}] = enriched["attempts"]
    assert git["selected_sha"] == sha
    assert git["on_origin"] == false

    GitFixture.git!(repo, ["push", "origin", "HEAD:main"])
    assert {:ok, %{"on_origin" => true}} = Attempts.selection(project, "prior")
  end

  test "missing branches remain explicit evidence", %{project: project} do
    :ok = ResultStore.record_run(record("missing", "fingerprint", "rejected"))
    assert {:ok, [task]} = Attempts.attach(project, [%{"id" => "1"}])
    assert [%{"git" => %{"error" => error}}] = task["attempts"]
    assert error =~ "git_failed"
    assert {:error, _} = Attempts.selection(project, "missing")
  end

  test "disabled history never means a first attempt", %{project: project} do
    Application.put_env(:harness, :result_store, false)
    assert {:error, :history_store_disabled} = Attempts.attach(project, [%{"id" => "1"}])
  end

  test "history database failures propagate without dispatchable empty history", %{project: project} do
    Application.put_env(:harness, :result_store, {Harness.ResultStore.Postgres, []})
    assert {:error, %RuntimeError{}} = Attempts.attach(project, [%{"id" => "1"}])
  end

  test "a genuine first attempt has empty history", %{project: project} do
    assert {:ok, [%{"attempts" => []}]} = Attempts.attach(project, [%{"id" => "1"}])
    assert {:error, :missing_target_branch} = Attempts.selection(%{project | target_branch: nil}, "prior")
  end

  defp record(id, fingerprint, report) do
    %LogRecord{
      batch_id: "batch",
      run_id: id,
      task_id: "1",
      task_ids: ["1"],
      project_name: "attempts",
      task_fingerprint: fingerprint,
      adapter: Harness.AgentAdapter.Codex,
      state: :failed,
      reason: {:review_rejected, report},
      duration_ms: 1,
      review_report: report,
      verdict: :reject
    }
  end
end
