defmodule Harness.Run.ReviewerPromptTest do
  use Harness.RunCase, async: true

  describe "the reviewer prompt" do
    test "frames the reviewer with the task, evidence, and the project's check hint" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()
      project = ProjectFixture.from_repo(repo, check_command: "mix precommit")

      opts =
        base
        |> default_opts()
        |> Keyword.put(:reviewer_adapter_opts, command: {:review_capture_prompt, "approve"})

      {:ok, run_id, pid} = Run.Supervisor.start_run(item(), project, FakeAdapter, opts)
      result = await_result(run_id, pid)

      assert %Result{state: :done, reason: :approved} = result

      prompt = GitFixture.git!(repo, ["show", "harness/#{run_id}:reviewer_prompt.txt"])
      assert prompt =~ "You are the cross-family reviewer for a harness run"
      assert prompt =~ "committed work in this SAME worktree"
      assert prompt =~ "Fixing is always cheaper than rejecting"
      assert prompt =~ "Reject ONLY if there is literally nothing to salvage"
      assert prompt =~ "Project check hint"
      assert prompt =~ "mix precommit"
      assert prompt =~ "Task spec:"
      assert prompt =~ "Acceptance criteria:"
      assert prompt =~ "Implementer transcript tail:"
      assert prompt =~ "Diff stat:"
      assert prompt =~ Review.artifact_path()
      assert prompt =~ "Discovery filing"
      assert prompt =~ "rmap new --from-stdin"
      assert prompt =~ project.roadmap_path
      assert prompt =~ "file it as a real rmap task"
      assert prompt =~ "name the filed task id"
    end

    test "makes rmap reachable inside the reviewer worktree even when PATH is scrubbed" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()
      rmap_dir = fake_rmap_dir()

      with_rmap_path_dirs([rmap_dir])

      opts =
        base
        |> default_opts()
        |> Keyword.merge(
          env: %{"PATH" => "/usr/bin:/bin"},
          reviewer_adapter_opts: [command: {:review_capture_rmap_path, "approve"}]
        )

      {:ok, run_id, pid} = Run.Supervisor.start_run(item(), ProjectFixture.from_repo(repo), FakeAdapter, opts)
      assert %Result{state: :done, reason: :approved} = await_result(run_id, pid)

      captured = GitFixture.git!(repo, ["show", "harness/#{run_id}:reviewer_rmap_path.txt"])
      assert String.trim(captured) == Path.join(rmap_dir, "rmap")
    end

    test "makes writing the verdict artifact the mandatory, unconditional FINAL action (Task 181)" do
      repo = GitFixture.init_repo()
      base = GitFixture.tmp_base()

      opts =
        base
        |> default_opts()
        |> Keyword.put(:reviewer_adapter_opts, command: {:review_capture_prompt, "approve"})

      {:ok, run_id, pid} = Run.Supervisor.start_run(item(), ProjectFixture.from_repo(repo), FakeAdapter, opts)
      assert %Result{state: :done, reason: :approved} = await_result(run_id, pid)

      prompt = GitFixture.git!(repo, ["show", "harness/#{run_id}:reviewer_prompt.txt"])
      # The root-cause fix for the reviewer-skips-verdict stall: the prompt must
      # frame the artifact write as the unconditional last step before exit.
      assert prompt =~ "FINAL action"
      assert prompt =~ "mandatory and unconditional"
      assert prompt =~ "go idle until the file is written"
    end

    test "an empty implementer diff is framed as the reviewer's judgment call" do
      result =
        run(
          adapter_opts: [command: :echo],
          reviewer_adapter_opts: [command: {:review_capture_prompt, "approve"}]
        )

      assert %Result{state: :done, reason: :approved, agent_diff_size: 0} = result

      # The worktree is removed on approve, but the prompt capture rides on the
      # run branch via the reviewer-fixes commit — read it from the result's
      # review instead: the framing is asserted through the retained worktree
      # on the reject variant below. Here we assert the run settled :done on
      # the reviewer's call, not on a procedural empty-diff branch.
    end

    test "an empty implementer diff the reviewer rejects keeps its framing inspectable" do
      result =
        run(
          adapter_opts: [command: :echo],
          reviewer_adapter_opts: [command: {:review_capture_prompt, "reject"}]
        )

      assert %Result{state: :failed, reason: {:review_rejected, _report}, agent_diff_size: 0} = result

      # Failure retains the worktree — the empty-diff framing is inspectable.
      prompt = File.read!(Path.join(result.worktree_path, "reviewer_prompt.txt"))
      assert prompt =~ "The implementer produced NO diff"
      assert prompt =~ "Decide"
      assert prompt =~ "what the empty diff means"
    end
  end
end
