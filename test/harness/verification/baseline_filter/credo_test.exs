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
    test "drops TagTODO findings whose (file, normalized trigger) is in the baseline" do
      baseline = MapSet.new([{"lib/inherited.ex", "# TODO(Task 35): inherited"}])

      issues = [
        tagtodo_issue("/wt/lib/inherited.ex", 3, trigger: "# TODO(Task 35): inherited"),
        tagtodo_issue("/wt/lib/inherited.ex", 7, trigger: "# TODO(Task 99): brand-new"),
        non_tagtodo_issue("/wt/lib/inherited.ex", 1)
      ]

      kept = BaselineCredo.filter_issues(issues, baseline, "/wt")

      # The baseline tag (matched by content) was dropped; the agent's
      # fresh tag at a different content and any non-TagTODO finding stay
      # so the verdict stays red.
      kept_triggers = Enum.map(kept, & &1["trigger"])
      assert "# TODO(Task 99): brand-new" in kept_triggers
      assert nil in kept_triggers
      refute "# TODO(Task 35): inherited" in kept_triggers
    end

    test "normalizes whitespace and leading code so git-grep and credo line up" do
      # git-grep returns the full source line (with any leading indent),
      # while credo's `trigger` field is anchored at the first `#`. Both
      # must normalize to the same key so a baseline carved from git-grep
      # matches credo's later issue output.
      baseline = MapSet.new([{"lib/x.ex", "# TODO: x"}])

      issue = tagtodo_issue("/wt/lib/x.ex", 1, trigger: "  # TODO: x  ")

      assert BaselineCredo.filter_issues([issue], baseline, "/wt") == []
    end

    test "REGRESSION (Task 55, same-line rewrite false-pass): rewriting an inherited TODO on its line reds correctly" do
      # Bug: previously the baseline keyed on {file, line_no}, so an agent
      # who edited the TODO content on the same line was silently filtered
      # as inherited debt. Content-keyed matching catches this.
      baseline = MapSet.new([{"lib/x.ex", "# TODO(Task 35): original wording"}])

      rewritten =
        tagtodo_issue("/wt/lib/x.ex", 3, trigger: "# TODO(Task 99): freshly added by the agent")

      assert [^rewritten] = BaselineCredo.filter_issues([rewritten], baseline, "/wt")
    end

    test "REGRESSION (Task 55, line-shift false-red): an inherited TODO whose line moved is still filtered" do
      # Bug: previously the baseline keyed on {file, line_no}, so any insert
      # or delete above an inherited TODO shifted its line_no and the
      # un-mutated TODO was flagged as new debt. Content-keyed matching
      # ignores the line shift.
      baseline = MapSet.new([{"lib/x.ex", "# TODO(Task 35): inherited"}])

      shifted =
        tagtodo_issue("/wt/lib/x.ex", 17, trigger: "# TODO(Task 35): inherited")

      assert BaselineCredo.filter_issues([shifted], baseline, "/wt") == []
    end

    test "falls open (does not filter) when the credo issue lacks a trigger field" do
      # Older credo or upstream churn could drop `trigger`. Failing open
      # preserves the red verdict — better a false-red than a false-pass.
      baseline = MapSet.new([{"lib/x.ex", "# TODO: x"}])

      issue =
        :tagtodo
        |> issue_fixture()
        |> Map.delete("trigger")
        |> Map.put("filename", "/wt/lib/x.ex")

      assert [^issue] = BaselineCredo.filter_issues([issue], baseline, "/wt")
    end

    test "is a no-op for issues whose check is not TagTODO" do
      baseline = MapSet.new([{"lib/inherited.ex", "# TODO: x"}])
      moduledoc = non_tagtodo_issue("/wt/lib/inherited.ex", 1)

      assert [^moduledoc] = BaselineCredo.filter_issues([moduledoc], baseline, "/wt")
    end

    test "is a no-op when the baseline set is empty" do
      issues = [tagtodo_issue("/wt/lib/x.ex", 2)]

      assert ^issues = BaselineCredo.filter_issues(issues, MapSet.new(), "/wt")
    end
  end

  describe "baseline_tagtodo_lines/2 (git-grep against a real repo)" do
    test "returns the set of pre-existing TODO (file, normalized content) pairs at the base ref" do
      {wt, _repo} = worktree_with_baseline_todo()
      assert {:ok, baseline} = BaselineCredo.baseline_tagtodo_lines(wt.path, wt.base_sha)

      assert MapSet.member?(
               baseline,
               {"lib/inherited.ex", "# TODO(Task 35): inherited from an audit follow-up"}
             )
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

    @inherited_trigger "# TODO(Task 35): inherited from an audit follow-up"

    test "no TagTODOs introduced by the agent → re-grades :pass" do
      {wt, _repo} = worktree_with_baseline_todo()

      {:ok, baseline} = BaselineCredo.baseline_tagtodo_lines(wt.path, wt.base_sha)

      # Simulate credo running on the worktree and only finding the
      # inherited TODO at lib/inherited.ex (line shifted is irrelevant —
      # content-keyed matching).
      issues = [
        tagtodo_issue(Path.join(wt.path, "lib/inherited.ex"), 3, trigger: @inherited_trigger)
      ]

      filtered = BaselineCredo.filter_issues(issues, baseline, wt.path)
      regraded = BaselineCredo.regrade(result(:fail, 2, "credo: 1 issue"), issues, filtered)

      assert regraded.status == :pass
    end

    test "agent introduces a new TODO not in the base → STILL reds" do
      {wt, _repo} = worktree_with_baseline_todo()

      {:ok, baseline} = BaselineCredo.baseline_tagtodo_lines(wt.path, wt.base_sha)

      # The inherited TODO plus a brand-new TODO the agent added at lib/new.ex
      # with content that's not in baseline.
      issues = [
        tagtodo_issue(Path.join(wt.path, "lib/inherited.ex"), 3, trigger: @inherited_trigger),
        tagtodo_issue(Path.join(wt.path, "lib/new.ex"), 4, trigger: "# TODO: brand-new addition")
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
        tagtodo_issue(Path.join(wt.path, "lib/inherited.ex"), 3, trigger: @inherited_trigger),
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

  defp tagtodo_issue(filename, line_no, opts \\ []) do
    %{
      "check" => "Credo.Check.Design.TagTODO",
      "filename" => filename,
      "line_no" => line_no,
      "category" => "design",
      "message" => "Found a TODO tag in a comment",
      "trigger" => Keyword.get(opts, :trigger, "# TODO: stub-#{line_no}")
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
