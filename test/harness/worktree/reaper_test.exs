defmodule Harness.Worktree.ReaperTest do
  use ExUnit.Case, async: false

  alias Harness.GitFixture
  alias Harness.ProjectFixture
  alias Harness.Worktree
  alias Harness.Worktree.Reaper

  @retained_marker ".harness-retained"
  @eventually_tries 50
  @eventually_delay_ms 10

  setup do
    # The app does not start the reaper in the test env (reap_on_crash: false);
    # start one supervised instance per test under its registered name.
    start_supervised!(Reaper)
    :ok
  end

  describe "crash reaping" do
    test "reclaims the worktree+branch of a run whose gen_statem crashes before settle" do
      {repo, wt} = create_worktree()
      run = spawn(fn -> Process.sleep(:infinity) end)

      Reaper.track(run, wt.id, wt.path, wt.repo)
      sync(run)

      crash(run)

      refute File.dir?(wt.path)
      assert GitFixture.git!(repo, ["branch", "--list", wt.branch]) == ""
    end

    test "keeps a retained (settled-:failed, kept-for-salvage) worktree even on a crash exit" do
      {repo, wt} = create_worktree()
      File.write!(Path.join(wt.path, @retained_marker), "")
      run = spawn(fn -> Process.sleep(:infinity) end)

      Reaper.track(run, wt.id, wt.path, wt.repo)
      sync(run)

      crash(run)

      assert File.dir?(wt.path)
      assert GitFixture.git!(repo, ["branch", "--list", wt.branch]) =~ wt.branch
    end

    test "retries once when registry liveness has not cleared before the crash DOWN is handled" do
      {repo, wt} = create_worktree()
      parent = self()

      live_holder =
        spawn(fn ->
          {:ok, _} = Registry.register(Harness.Run.Registry, wt.id, nil)
          send(parent, :registered)

          receive do
            :unregister -> :ok
          end
        end)

      assert_receive :registered
      on_exit(fn -> Process.exit(live_holder, :kill) end)

      run = spawn(fn -> Process.sleep(:infinity) end)

      Reaper.track(run, wt.id, wt.path, wt.repo)
      sync(run)

      crash(run)

      assert File.dir?(wt.path)

      send(live_holder, :unregister)
      assert_reaped(repo, wt)
    end
  end

  describe "non-crash exits are never reaped" do
    test "a normal exit (a clean settle's lifecycle end) leaves the worktree intact" do
      {repo, wt} = create_worktree()
      run = spawn(fn -> receive do: (:stop -> :ok) end)

      Reaper.track(run, wt.id, wt.path, wt.repo)
      sync(run)

      ref = Process.monitor(run)
      send(run, :stop)
      assert_receive {:DOWN, ^ref, :process, ^run, :normal}
      :sys.get_state(Reaper)

      assert File.dir?(wt.path)
      assert GitFixture.git!(repo, ["branch", "--list", wt.branch]) =~ wt.branch
    end

    test "an untracked run (settle ran) is not reaped when it later dies" do
      {repo, wt} = create_worktree()
      run = spawn(fn -> Process.sleep(:infinity) end)

      Reaper.track(run, wt.id, wt.path, wt.repo)
      sync(run)
      Reaper.untrack(wt.id)
      :sys.get_state(Reaper)

      crash(run)

      assert File.dir?(wt.path)
      assert GitFixture.git!(repo, ["branch", "--list", wt.branch]) =~ wt.branch
    end
  end

  # Brutally kill the tracked run and block until the reaper has fully processed
  # the resulting monitor :DOWN (including any cleanup_for_run git work). Waiting
  # on our OWN monitor :DOWN first is the sync: once a co-monitor sees the death,
  # every monitor's :DOWN is enqueued, so the reaper's :DOWN precedes the
  # subsequent :sys.get_state flush.
  @spec crash(pid()) :: :ok
  defp crash(run) do
    ref = Process.monitor(run)
    Process.exit(run, :kill)
    assert_receive {:DOWN, ^ref, :process, ^run, :killed}
    :sys.get_state(Reaper)
    :ok
  end

  # Flush the reaper's mailbox up to and including the prior track cast (a cast
  # from this process is ordered before this same-process :sys.get_state call).
  @spec sync(pid()) :: :ok
  defp sync(_run) do
    :sys.get_state(Reaper)
    :ok
  end

  @spec assert_reaped(String.t(), Worktree.t(), pos_integer()) :: :ok
  defp assert_reaped(repo, wt, tries \\ @eventually_tries)

  defp assert_reaped(repo, wt, tries) when tries > 1 do
    if File.dir?(wt.path) or branch_exists?(repo, wt.branch) do
      Process.sleep(@eventually_delay_ms)
      assert_reaped(repo, wt, tries - 1)
    else
      :ok
    end
  end

  defp assert_reaped(repo, wt, 1) do
    refute File.dir?(wt.path), "expected #{wt.path} to be reaped after retry"
    assert GitFixture.git!(repo, ["branch", "--list", wt.branch]) == ""
    :ok
  end

  @spec branch_exists?(String.t(), String.t()) :: boolean()
  defp branch_exists?(repo, branch), do: GitFixture.git!(repo, ["branch", "--list", branch]) != ""

  @spec create_worktree() :: {String.t(), Worktree.t()}
  defp create_worktree do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    {:ok, wt} = Worktree.create(ProjectFixture.from_repo(repo), base_dir: base)
    {repo, wt}
  end
end
