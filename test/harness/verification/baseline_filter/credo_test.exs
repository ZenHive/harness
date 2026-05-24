defmodule Harness.Verification.BaselineFilter.CredoTest do
  # Each test gets its own throwaway repo, so cases never share git state.
  use ExUnit.Case, async: true

  alias Harness.GitFixture
  alias Harness.Verification.BaselineFilter.Credo, as: BaselineCredo
  alias Harness.Verification.Result
  alias Harness.Worktree

  describe "apply/2 defensive paths" do
    test "returns a :pass result unchanged" do
      result = result(:pass, 0, "all good")

      assert ^result = BaselineCredo.apply(result, worktree_path: "/tmp/ignored", base_ref: "abc")
    end

    test "returns a red result unchanged when :base_ref is missing" do
      result = result(:fail, 2, "credo: some issue")

      assert ^result = BaselineCredo.apply(result, worktree_path: "/tmp/ignored")
    end

    test "returns a red result unchanged when :worktree_path is missing" do
      result = result(:fail, 2, "credo: some issue")

      assert ^result = BaselineCredo.apply(result, base_ref: "abc")
    end
  end

  describe "regrade/3 (pure)" do
    test "re-grades :pass and annotates when every issue was filtered" do
      red = result(:fail, 2, "credo: 1 issue")
      regraded = BaselineCredo.regrade(red, [issue_fixture(:tagtodo)], [])

      assert regraded.status == :pass
      # Process exit status is preserved as evidence — the filter overrides
      # the verdict, not the captured raw output of the run.
      assert regraded.exit_status == 2
      assert regraded.output =~ "all findings were pre-existing TagTODOs"
    end

    test "keeps :fail but annotates the drop count when some issues remain" do
      red = result(:fail, 2, "credo: 3 issues")

      regraded =
        BaselineCredo.regrade(
          red,
          [issue_fixture(:tagtodo), issue_fixture(:tagtodo), issue_fixture(:moduledoc)],
          [issue_fixture(:moduledoc)]
        )

      assert regraded.status == :fail
      assert regraded.output =~ "2 pre-existing TagTODO finding(s) were filtered"
      assert regraded.output =~ "1 finding(s) remain"
    end

    test "leaves the result untouched when nothing was filtered" do
      red = result(:fail, 2, "credo: 2 issues")
      issues = [issue_fixture(:moduledoc), issue_fixture(:moduledoc)]

      assert ^red = BaselineCredo.regrade(red, issues, issues)
    end
  end

  describe "filter_issues/3 (pure)" do
    test "drops TagTODO findings whose (file, line) is in the baseline" do
      baseline = MapSet.new([{"lib/inherited.ex", 3}])

      issues = [
        tagtodo_issue("/wt/lib/inherited.ex", 3),
        tagtodo_issue("/wt/lib/inherited.ex", 7),
        non_tagtodo_issue("/wt/lib/inherited.ex", 1)
      ]

      kept = BaselineCredo.filter_issues(issues, baseline, "/wt")

      # The baseline TODO at line 3 was dropped; the agent's new TODO at
      # line 7 and any non-TagTODO finding stay so the verdict stays red.
      kept_lines = Enum.map(kept, &{&1["filename"], &1["line_no"]})
      assert {"/wt/lib/inherited.ex", 7} in kept_lines
      assert {"/wt/lib/inherited.ex", 1} in kept_lines
      refute {"/wt/lib/inherited.ex", 3} in kept_lines
    end

    test "is a no-op for issues whose check is not TagTODO" do
      baseline = MapSet.new([{"lib/inherited.ex", 1}])
      moduledoc = non_tagtodo_issue("/wt/lib/inherited.ex", 1)

      assert [^moduledoc] = BaselineCredo.filter_issues([moduledoc], baseline, "/wt")
    end

    test "is a no-op when the baseline set is empty" do
      issues = [tagtodo_issue("/wt/lib/x.ex", 2)]

      assert ^issues = BaselineCredo.filter_issues(issues, MapSet.new(), "/wt")
    end
  end

  describe "baseline_tagtodo_lines/2 (git-grep against a real repo)" do
    test "returns the set of pre-existing TODO (file, line) pairs at the base ref" do
      {wt, _repo} = worktree_with_baseline_todo()
      assert {:ok, baseline} = BaselineCredo.baseline_tagtodo_lines(wt.path, wt.base_sha)

      assert MapSet.member?(baseline, {"lib/inherited.ex", 3})
    end

    test "returns an empty set when the dispatch base has no TODOs" do
      {wt, _repo} = worktree_without_todos()
      assert {:ok, baseline} = BaselineCredo.baseline_tagtodo_lines(wt.path, wt.base_sha)

      assert MapSet.size(baseline) == 0
    end

    test "returns :error when the ref does not resolve in the repo" do
      {wt, _repo} = worktree_without_todos()
      bogus = "0000000000000000000000000000000000000000"

      assert :error = BaselineCredo.baseline_tagtodo_lines(wt.path, bogus)
    end
  end

  describe "acceptance: integration of git-grep + filter_issues + regrade" do
    # End-to-end checks that match Task 43's acceptance criteria. The credo
    # invocation itself is bypassed (the throwaway worktree is not a mix
    # project) by hand-feeding `filter_issues/3` the issues credo would
    # produce — the baseline-collection + filter + re-grade logic runs
    # exactly as it would from `apply/2`.

    test "no TagTODOs introduced by the agent → re-grades :pass" do
      {wt, _repo} = worktree_with_baseline_todo()

      {:ok, baseline} = BaselineCredo.baseline_tagtodo_lines(wt.path, wt.base_sha)

      # Simulate credo running on the worktree and only finding the
      # inherited TODO at lib/inherited.ex:3.
      issues = [tagtodo_issue(Path.join(wt.path, "lib/inherited.ex"), 3)]
      filtered = BaselineCredo.filter_issues(issues, baseline, wt.path)
      regraded = BaselineCredo.regrade(result(:fail, 2, "credo: 1 issue"), issues, filtered)

      assert regraded.status == :pass
    end

    test "agent introduces a new TODO not in the base → STILL reds" do
      {wt, _repo} = worktree_with_baseline_todo()

      {:ok, baseline} = BaselineCredo.baseline_tagtodo_lines(wt.path, wt.base_sha)

      # The inherited TODO at line 3 plus a brand-new TODO the agent added
      # at lib/new.ex line 4 (not in baseline).
      issues = [
        tagtodo_issue(Path.join(wt.path, "lib/inherited.ex"), 3),
        tagtodo_issue(Path.join(wt.path, "lib/new.ex"), 4)
      ]

      filtered = BaselineCredo.filter_issues(issues, baseline, wt.path)
      regraded = BaselineCredo.regrade(result(:fail, 2, "credo: 2 issues"), issues, filtered)

      assert regraded.status == :fail
      assert regraded.output =~ "1 pre-existing TagTODO finding(s) were filtered"
      assert regraded.output =~ "1 finding(s) remain"
    end

    test "non-TagTODO finding present → STILL reds even with all baseline TODOs filtered" do
      {wt, _repo} = worktree_with_baseline_todo()

      {:ok, baseline} = BaselineCredo.baseline_tagtodo_lines(wt.path, wt.base_sha)

      issues = [
        tagtodo_issue(Path.join(wt.path, "lib/inherited.ex"), 3),
        non_tagtodo_issue(Path.join(wt.path, "lib/undocumented.ex"), 1)
      ]

      filtered = BaselineCredo.filter_issues(issues, baseline, wt.path)
      regraded = BaselineCredo.regrade(result(:fail, 2, "credo: 2 issues"), issues, filtered)

      assert regraded.status == :fail
    end
  end

  defp result(status, exit_status, output) do
    %Result{
      name: "credo",
      command: "mix",
      status: status,
      kind: :exited,
      exit_status: exit_status,
      output: output
    }
  end

  defp issue_fixture(:tagtodo), do: tagtodo_issue("/wt/lib/x.ex", 1)
  defp issue_fixture(:moduledoc), do: non_tagtodo_issue("/wt/lib/x.ex", 1)

  defp tagtodo_issue(filename, line_no) do
    %{
      "check" => "Credo.Check.Design.TagTODO",
      "filename" => filename,
      "line_no" => line_no,
      "category" => "design",
      "message" => "Found a TODO tag in a comment"
    }
  end

  defp non_tagtodo_issue(filename, line_no) do
    %{
      "check" => "Credo.Check.Readability.ModuleDoc",
      "filename" => filename,
      "line_no" => line_no,
      "category" => "readability",
      "message" => "Modules should have a @moduledoc tag."
    }
  end

  # Builds a freshly-init'd repo + worktree carved from HEAD, where HEAD has
  # a single todo-tag baseline comment at `lib/inherited.ex:3`. The worktree's
  # `base_sha` points exactly at that HEAD.
  defp worktree_with_baseline_todo do
    repo = GitFixture.init_repo()
    File.mkdir_p!(Path.join(repo, "lib"))

    File.write!(Path.join([repo, "lib", "inherited.ex"]), """
    defmodule Inherited do
      @moduledoc false
      # TODO(Task 35): inherited from an audit follow-up
      def hello, do: :world
    end
    """)

    GitFixture.git!(repo, ["add", "lib/inherited.ex"])
    GitFixture.git!(repo, ["commit", "-q", "-m", "seed: inherited TODO"])

    {:ok, wt} = Worktree.create(repo, base_dir: GitFixture.tmp_base())
    {wt, repo}
  end

  defp worktree_without_todos do
    repo = GitFixture.init_repo()
    {:ok, wt} = Worktree.create(repo, base_dir: GitFixture.tmp_base())
    {wt, repo}
  end
end
