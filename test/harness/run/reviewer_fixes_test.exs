defmodule Harness.Run.ReviewerFixesTest do
  use Harness.RunCase, async: true

  describe "the reviewer's own fixes" do
    test "reviewer fixes are committed on the run branch and measured as reviewer diff" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()
      store = file_store()

      opts =
        base
        |> default_opts()
        |> Keyword.merge(
          reviewer_adapter_opts: [command: {:review_with_fix, "approve"}],
          result_store: store
        )

      {:ok, run_id, pid} = Run.Supervisor.start_run(item(), ProjectFixture.from_repo(repo), FakeAdapter, opts)
      result = await_result(run_id, pid)

      assert %Result{state: :done, reason: :approved} = result
      assert result.reviewer_diff_size > 0
      assert GitFixture.git!(repo, ["show", "harness/#{run_id}:reviewer_fix.txt"]) =~ "reviewer-fix"

      # The fix is attributed to the reviewer in the persisted record.
      assert {:ok, [record]} = ResultStore.list_run_records(store, run_id: run_id)
      assert record.reviewer_diff_size > 0
      assert record.review_iterations == 1
      assert record.reviewer_adapter == FakeAdapter
    end

    test "a clean approve measures zero reviewer diff (first-attempt pass)" do
      result = run([])

      assert %Result{state: :done, reason: :approved, reviewer_diff_size: 0} = result
    end
  end
end
