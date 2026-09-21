defmodule Harness.Lander.PRPollerTest do
  @moduledoc """
  Mechanical PR-merge poller: OPEN is a no-op, MERGED writeback is once,
  CLOSED-unmerged blocks with the URL in the reason.
  """
  use ExUnit.Case, async: false

  alias Harness.AgentAdapter.Claude
  alias Harness.AgentAdapter.Codex
  alias Harness.Cron.Settings
  alias Harness.GitFixture
  alias Harness.Lander.PRPoller
  alias Harness.Notification.Event
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry
  alias Harness.ResultStore
  alias Harness.ResultStore.Memory
  alias Harness.Run.LogRecord
  alias Harness.SettingsStore
  alias Harness.Test.CaptureSink
  alias Harness.Test.SettingsStoreMemory
  alias Oban.Job

  @pr_url "https://github.com/acme/harness/pull/7"
  @merge_sha "abc123deadbeef"

  setup do
    %{repo: repo} = GitFixture.init_with_origin()
    roadmap = Harness.LandingFixture.roadmap()
    merge_sha = repo |> GitFixture.git!(["rev-parse", "HEAD"]) |> String.trim()

    project = %{
      ProjectFixture.from_repo(repo, name: "pr-poll")
      | landing_policy: :pr,
        target_branch: "main",
        roadmap_path: roadmap.repo,
        roadmap_target_branch: "main"
    }

    :ok = ProjectRegistry.register(project)

    store = {Memory, scope: {:pr_poller, self(), System.unique_integer([:positive])}}
    previous_store = Application.get_env(:harness, :result_store)
    previous_gh = Application.get_env(:harness, :gh_cmd)
    Application.put_env(:harness, :result_store, store)

    Application.put_env(:harness, :notification_sinks, [CaptureSink])
    Application.put_env(:harness, :test_capture_pid, self())

    SettingsStoreMemory.reset(scope: :test_default)

    test_pid = self()

    Application.put_env(:harness, :oban_insert, fn changeset ->
      send(test_pid, {:audit_insert, changeset})
      {:ok, %Job{}}
    end)

    on_exit(fn ->
      ProjectRegistry.unregister(project.name)
      restore(:result_store, previous_store)
      restore(:gh_cmd, previous_gh)
      Application.delete_env(:harness, :notification_sinks)
      Application.delete_env(:harness, :test_capture_pid)
      Application.delete_env(:harness, :oban_insert)
      Memory.reset(elem(store, 1))
      SettingsStoreMemory.reset(scope: :test_default)
    end)

    {:ok, project: project, store: store, roadmap: roadmap, merge_sha: merge_sha, repo: repo}
  end

  describe "open_pr?/1" do
    test "requires a pr_url and incomplete PR writeback even after delivery lands" do
      base = log_record("pr-poll")

      assert PRPoller.open_pr?(%{base | pr_url: @pr_url, pr_writeback: :opened, landed_sha: nil})
      assert PRPoller.open_pr?(%{base | pr_url: @pr_url, pr_writeback: nil, landed_sha: nil})
      refute PRPoller.open_pr?(%{base | pr_url: nil, pr_writeback: :opened, landed_sha: nil})
      refute PRPoller.open_pr?(%{base | pr_url: @pr_url, pr_writeback: :merged, landed_sha: nil})
      assert PRPoller.open_pr?(%{base | pr_url: @pr_url, pr_writeback: :opened, landed_sha: @merge_sha})
      refute PRPoller.open_pr?(%{base | pr_url: @pr_url, pr_writeback: :closed, landed_sha: nil})
    end
  end

  describe "cron_entry/0" do
    test "defaults to every 5 minutes" do
      assert {schedule, PRPoller, opts} = PRPoller.cron_entry()
      assert schedule == "*/5 * * * *"
      assert opts[:queue] == :cron
      assert Settings.pr_poll_schedule() == "*/5 * * * *"
    end

    test "a persisted crontab round-trips" do
      assert :ok = SettingsStore.put(:cron, %{pr_poll_schedule: "*/10 * * * *"})
      assert Settings.pr_poll_schedule() == "*/10 * * * *"
      assert PRPoller.schedule() == "*/10 * * * *"
    end
  end

  describe "perform/1" do
    test "OPEN is a no-op" do
      :ok = ResultStore.record_run(open_record("pr-poll"))

      stub_view(%{
        "state" => "OPEN",
        "mergeCommit" => nil,
        "mergedAt" => nil
      })

      assert :ok = PRPoller.perform(%Job{})

      assert {:ok, [record]} = ResultStore.list_run_records(run_id: "run-pr")
      assert record.landed_sha == nil
      assert record.pr_writeback == :opened
      refute_receive {:notify, _event}, 200
      refute_receive {:audit_insert, _changeset}, 200
    end

    test "MERGED writeback is idempotent and enqueues audit once", %{merge_sha: merge_sha} do
      :ok = ResultStore.record_run(open_record("pr-poll"))

      stub_view(%{
        "state" => "MERGED",
        "mergeCommit" => %{"oid" => merge_sha},
        "mergedAt" => "2026-09-13T01:00:00Z"
      })

      assert :ok = PRPoller.perform(%Job{})

      assert {:ok, [record]} = ResultStore.list_run_records(run_id: "run-pr")
      assert record.landed_sha == merge_sha
      assert record.pr_writeback == :merged

      assert_receive {:notify, %Event{type: :landed, outcome: ^merge_sha, task_id: "1"}}
      assert_receive {:audit_insert, _changeset}, 1_000

      assert :ok = PRPoller.perform(%Job{})
      refute_receive {:notify, %Event{type: :landed}}, 200
      refute_receive {:audit_insert, _changeset}, 200
    end

    test "CLOSED with a merge commit writes back as merged (not blocked)", %{merge_sha: merge_sha} do
      :ok = ResultStore.record_run(open_record("pr-poll"))

      stub_view(%{
        "state" => "CLOSED",
        "mergeCommit" => %{"oid" => merge_sha},
        "mergedAt" => "2026-09-13T01:00:00Z"
      })

      assert :ok = PRPoller.perform(%Job{})

      assert {:ok, [record]} = ResultStore.list_run_records(run_id: "run-pr")
      assert record.landed_sha == merge_sha
      assert record.pr_writeback == :merged

      assert_receive {:notify, %Event{type: :landed, outcome: ^merge_sha, task_id: "1"}}
      refute_receive {:notify, %Event{type: :blocked}}, 200
    end

    test "CLOSED without merge marks blocked with the PR URL" do
      :ok = ResultStore.record_run(open_record("pr-poll"))

      stub_view(%{
        "state" => "CLOSED",
        "mergeCommit" => nil,
        "mergedAt" => nil
      })

      assert :ok = PRPoller.perform(%Job{})

      assert {:ok, [record]} = ResultStore.list_run_records(run_id: "run-pr")
      assert record.pr_writeback == :closed
      assert record.landed_sha == nil

      assert_receive {:notify, %Event{type: :blocked, outcome: reason}}
      assert reason == "PR #{@pr_url} closed unmerged"
    end
  end

  test "merged writeback failure is retried from persisted delivery without polling GitHub", ctx do
    record = %{open_record("pr-poll") | task_ids: ["1", "2"]}
    :ok = ResultStore.record_run(record)
    hook = Path.join(ctx.roadmap.origin, "hooks/pre-receive")
    File.write!(hook, "#!/bin/sh\nexit 1\n")
    File.chmod!(hook, 0o755)
    stub_view(%{"state" => "MERGED", "mergeCommit" => %{"oid" => ctx.merge_sha}})

    assert :ok = PRPoller.perform(%Job{})
    assert {:ok, failed} = ResultStore.fetch_run_record("run-pr")
    assert failed.landed_sha == ctx.merge_sha
    assert failed.pr_writeback == :opened
    assert failed.roadmap_writeback["status"] == "pending"
    assert failed.roadmap_writeback["task_ids"] == ["1", "2"]
    refute_receive {:notify, %Event{type: :landed}}

    File.rm!(hook)
    Application.put_env(:harness, :gh_cmd, fn args, _opts -> flunk("unexpected gh retry: #{inspect(args)}") end)
    assert :ok = PRPoller.perform(%Job{})
    assert {:ok, complete} = ResultStore.fetch_run_record("run-pr")
    assert complete.pr_writeback == :merged
    assert complete.roadmap_writeback["status"] == "complete"

    for id <- ["1", "2"] do
      task = Harness.LandingFixture.origin_task(ctx.roadmap.origin, id)
      assert task["status"] == "done"
      assert task["shipped_in"] == ctx.merge_sha
      assert task["verification_ref"] == "harness-run:run-pr"
    end

    assert :ok = PRPoller.perform(%Job{})
  end

  @spec stub_view(map()) :: :ok
  defp stub_view(json) do
    Application.put_env(:harness, :gh_cmd, fn
      ["pr", "view", @pr_url, "--json", "state,mergeCommit,mergedAt"], _opts ->
        {Jason.encode!(json), 0}

      args, _opts ->
        flunk("unexpected gh #{inspect(args)}")
    end)
  end

  @spec open_record(String.t()) :: LogRecord.t()
  defp open_record(project_name) do
    %{log_record(project_name) | pr_url: @pr_url, pr_writeback: :opened}
  end

  @spec log_record(String.t()) :: LogRecord.t()
  defp log_record(project_name) do
    %LogRecord{
      batch_id: "batch-run-pr",
      run_id: "run-pr",
      task_id: "1",
      project_name: project_name,
      adapter: Claude,
      reviewer_adapter: Codex,
      agent: :claude,
      state: :done,
      reason: :approved,
      verdict: :approve,
      duration_ms: 1
    }
  end

  @spec restore(atom(), term()) :: :ok
  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)
end
