defmodule Harness.Lander.ResolverTest do
  @moduledoc """
  Coverage for the *judgment-free* surface of the merge-resolver (Task 189):
  the cross-family selection invariant and the prompt it hands the agent.

  The agent half (`resolve/2` driving a real CLI) is exercised end-to-end —
  including the git stage/assert/continue finalize and the fallback path — by
  `Harness.LanderTest`'s injected-resolver tests, which never spawn a CLI.
  """

  use ExUnit.Case, async: false

  alias Harness.AgentAdapter.Claude
  alias Harness.AgentAdapter.Codex
  alias Harness.GitFixture
  alias Harness.Lander.Resolver

  describe "select_resolver/2 — cross-family discipline" do
    test "never returns the implementer's own adapter (claude)" do
      result = Resolver.select_resolver(:claude, :claude)

      # Either no eligible cross-family agent is installed (=> :no_resolver) or a
      # module is chosen — but it is NEVER the implementer's own family.
      refute match?({:ok, Claude}, result)
      assert match?({:ok, _module}, result) or result == {:error, :no_resolver}
    end

    test "never returns the implementer's own adapter (codex)" do
      result = Resolver.select_resolver(:codex, :codex)

      refute match?({:ok, Codex}, result)
      assert match?({:ok, _module}, result) or result == {:error, :no_resolver}
    end
  end

  describe "build_prompt/3 — what the resolver is handed" do
    setup do
      repo = GitFixture.init_repo(name: "resolver")
      base_sha = repo |> GitFixture.git!(["rev-parse", "HEAD"]) |> String.trim()
      %{repo: repo, base_sha: base_sha}
    end

    test "lists every conflicted file and frames the keep-both, no-recheck job", %{repo: repo, base_sha: base_sha} do
      files = ["lib/a.ex", "test/a_test.exs"]
      prompt = Resolver.build_prompt(repo, files, task_id: "189", base_sha: base_sha)

      # criterion 2: conflicted file list + the run's task id (its intent anchor)
      assert prompt =~ "lib/a.ex"
      assert prompt =~ "test/a_test.exs"
      assert prompt =~ "task #189"

      # criterion 4: reconcile markers only — no re-run, no re-grade
      assert prompt =~ "KEEPING BOTH"
      assert prompt =~ "Do NOT run the project's tests"
      assert prompt =~ "NOT re-reviewing"
      assert prompt =~ "leave ZERO conflict markers"
    end

    test "renders the 'ours' intent from base_sha and tolerates a missing REBASE_HEAD", %{
      repo: repo,
      base_sha: base_sha
    } do
      prompt = Resolver.build_prompt(repo, ["lib/a.ex"], task_id: "189", base_sha: base_sha)

      # not mid-rebase here, so REBASE_HEAD is absent -> "theirs" degrades gracefully.
      assert prompt =~ ~s|("theirs", task #189)|
      assert prompt =~ "(unavailable)"
      # "ours" log resolves against the real base sha (the init commit subject).
      assert prompt =~ "init"
    end
  end
end
