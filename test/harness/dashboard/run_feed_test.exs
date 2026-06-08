defmodule Harness.Dashboard.RunFeedTest do
  use ExUnit.Case, async: true

  alias Harness.Dashboard.RunFeed
  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.Run.Status

  defp status(run_id, state) do
    %Status{run_id: run_id, task_id: "1", state: state}
  end

  describe "subscribe/0 + broadcast_update/1" do
    test "a subscriber receives non-terminal updates on the fleet topic" do
      assert :ok = RunFeed.subscribe()
      st = status("rf-1", :running)

      assert :ok = RunFeed.broadcast_update(st)
      assert_receive {:harness_run_update, ^st}
    end
  end

  describe "broadcast_settled/1" do
    test "a subscriber receives the terminal status" do
      assert :ok = RunFeed.subscribe()
      st = status("rf-2", :done)

      assert :ok = RunFeed.broadcast_settled(st)
      assert_receive {:harness_run_settled, ^st}
    end
  end

  describe "unsubscribe/0" do
    test "stops delivery after unsubscribe" do
      :ok = RunFeed.subscribe()
      :ok = RunFeed.unsubscribe()

      RunFeed.broadcast_update(status("rf-3", :running))
      refute_receive {:harness_run_update, _}, 100
    end
  end

  test "topic/0 is the stable fleet topic" do
    assert RunFeed.topic() == "harness:runs"
  end

  # The render-path landed_sha/3 is pure (roadmap witness || cache lookup) — no
  # git, no network (task 244). The branch-reachability work lives in the
  # cold-path builder branch_landed_cache/3, which consults LOCAL refs only. The
  # setup fetches origin into the local tracking ref itself (the render path no
  # longer does), exercising the no-network-in-render contract.
  describe "branch_landed_cache/3 + landed_sha/3 (no network in render)" do
    test "reports landed when the run branch tip is reachable from origin target without a roadmap writeback" do
      %{repo: repo} = GitFixture.init_with_origin(name: "run-feed-landed")
      project = ProjectFixture.from_repo(repo, name: "feed-proj", target_branch: "main")

      GitFixture.git!(repo, ["checkout", "-b", "harness/run-landed"])
      File.write!(Path.join(repo, "landed.txt"), "directly landed\n")
      GitFixture.git!(repo, ["add", "landed.txt"])
      GitFixture.git!(repo, ["commit", "-q", "-m", "harness: agent delivery - task 1 Direct land (run run-landed)"])
      sha = repo |> GitFixture.git!(["rev-parse", "HEAD"]) |> String.trim()
      GitFixture.git!(repo, ["checkout", "main"])
      GitFixture.git!(repo, ["push", "-q", "origin", "#{sha}:refs/heads/main"])
      GitFixture.git!(repo, ["fetch", "-q", "origin", "+main:refs/remotes/origin/main"])

      status = %Status{run_id: "run-landed", task_id: "1", project_name: project.name, state: :done}
      summaries = %{project.name => %{open: 1, done: 0, total: 1, landed: %{}, blocked: %{}}}

      cache = RunFeed.branch_landed_cache([status], summaries, [project])
      assert cache == %{"run-landed" => sha}
      assert RunFeed.landed_sha(status, summaries, cache) == sha
    end

    test "reports landed via target-branch commit message when the run branch tip was rebased away" do
      %{repo: repo} = GitFixture.init_with_origin(name: "run-feed-rebased")
      project = ProjectFixture.from_repo(repo, name: "feed-proj", target_branch: "main")

      GitFixture.git!(repo, ["checkout", "-b", "harness/run-rebased"])
      File.write!(Path.join(repo, "rebased.txt"), "rebased land\n")
      GitFixture.git!(repo, ["add", "rebased.txt"])
      GitFixture.git!(repo, ["commit", "-q", "-m", "harness: agent delivery - task 1 Rebasing land (run run-rebased)"])

      GitFixture.git!(repo, ["checkout", "main"])
      File.write!(Path.join(repo, "rebased.txt"), "rebased land\n")
      GitFixture.git!(repo, ["add", "rebased.txt"])
      GitFixture.git!(repo, ["commit", "-q", "-m", "harness: agent delivery - task 1 Rebasing land (run run-rebased)"])
      landed_sha = repo |> GitFixture.git!(["rev-parse", "HEAD"]) |> String.trim()
      GitFixture.git!(repo, ["push", "-q", "origin", "main:refs/heads/main"])
      GitFixture.git!(repo, ["fetch", "-q", "origin", "+main:refs/remotes/origin/main"])

      status = %Status{run_id: "run-rebased", task_id: "1", project_name: project.name, state: :done}
      summaries = %{project.name => %{open: 1, done: 0, total: 1, landed: %{}, blocked: %{}}}

      cache = RunFeed.branch_landed_cache([status], summaries, [project])
      assert cache == %{"run-rebased" => landed_sha}
      assert RunFeed.landed_sha(status, summaries, cache) == landed_sha
    end

    test "reports not-landed when an approved run branch is not reachable from origin target" do
      %{repo: repo} = GitFixture.init_with_origin(name: "run-feed-unlanded")
      project = ProjectFixture.from_repo(repo, name: "feed-proj", target_branch: "main")

      GitFixture.git!(repo, ["checkout", "-b", "harness/run-unlanded"])
      File.write!(Path.join(repo, "unlanded.txt"), "not landed\n")
      GitFixture.git!(repo, ["add", "unlanded.txt"])
      GitFixture.git!(repo, ["commit", "-q", "-m", "harness: agent delivery - task 1 Unlanded (run run-unlanded)"])
      GitFixture.git!(repo, ["checkout", "main"])

      status = %Status{run_id: "run-unlanded", task_id: "1", project_name: project.name, state: :done}
      summaries = %{project.name => %{open: 1, done: 0, total: 1, landed: %{}, blocked: %{}}}

      cache = RunFeed.branch_landed_cache([status], summaries, [project])
      assert cache == %{}
      assert RunFeed.landed_sha(status, summaries, cache) == nil
    end

    test "roadmap shipped_in witness short-circuits the cache (no git for witnessed rows)" do
      project = ProjectFixture.from_repo(GitFixture.init_repo(name: "run-feed-witness"), name: "feed-proj")

      status = %Status{run_id: "run-witnessed", task_id: "1", project_name: project.name, state: :done}
      summaries = %{project.name => %{open: 0, done: 1, total: 1, landed: %{"1" => "abc123"}, blocked: %{}}}

      # Witnessed rows are skipped by the builder; landed_sha resolves via the roadmap.
      assert RunFeed.branch_landed_cache([status], summaries, [project]) == %{}
      assert RunFeed.landed_sha(status, summaries, %{}) == "abc123"
    end
  end
end
