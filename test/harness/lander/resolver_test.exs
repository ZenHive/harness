defmodule Harness.Lander.ResolverTest do
  @moduledoc """
  Coverage for the *judgment-free* surface of the merge-resolver (Task 189):
  the cross-family selection invariant and the prompt it hands the agent.

  The agent half (`resolve/2` driving a real CLI) is exercised end-to-end —
  including the git stage/assert/continue finalize and the fallback path — by
  `Harness.LanderTest`'s injected-resolver tests, which never spawn a CLI.
  """

  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Claude
  alias Harness.AgentAdapter.Codex
  alias Harness.AgentRegistry
  alias Harness.GitFixture
  alias Harness.Lander.Resolver
  alias Harness.Worktree

  @long_conflict_payload_chars 4_100

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

    test "returns :no_resolver when no cross-family resolver is installed" do
      AgentRegistry.reset()
      mark_all_installed(false)
      on_exit(fn -> AgentRegistry.reset() end)

      assert Resolver.select_resolver(nil, nil) == {:error, :no_resolver}
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

    test "includes conflict excerpts and same-list additive guidance", %{repo: repo, base_sha: base_sha} do
      File.mkdir_p!(Path.join(repo, "src"))

      File.write!(Path.join(repo, "src/cli.ts"), """
      const SUBCOMMANDS = [
      <<<<<<< HEAD
        "update-ccxt",
      =======
        "validate",
      >>>>>>> task-2
      ];
      """)

      prompt = Resolver.build_prompt(repo, ["src/cli.ts"], task_id: "2", base_sha: base_sha)

      assert prompt =~ "Conflict excerpts"
      assert prompt =~ "src/cli.ts"
      assert prompt =~ ~s("update-ccxt")
      assert prompt =~ ~s("validate")
      assert prompt =~ "same function, same list"
      assert prompt =~ "keep every added command"
    end

    test "conflict excerpts handle marker-free and long marker snapshots", %{repo: repo, base_sha: base_sha} do
      File.mkdir_p!(Path.join(repo, "src"))
      File.write!(Path.join(repo, "src/no_markers.ts"), "const ok = true;\n")

      long_payload = String.duplicate("x", @long_conflict_payload_chars)

      File.write!(Path.join(repo, "src/long.ts"), """
      <<<<<<< HEAD
      #{long_payload}
      =======
      branch
      >>>>>>> task
      """)

      prompt = Resolver.build_prompt(repo, ["src/no_markers.ts", "src/long.ts"], task_id: "293", base_sha: base_sha)

      assert prompt =~ "src/no_markers.ts: no conflict markers found"
      assert prompt =~ "src/long.ts"
      assert prompt =~ "...[truncated]"
    end

    test "renders unavailable ours intent when base_sha is absent", %{repo: repo} do
      prompt = Resolver.build_prompt(repo, ["lib/a.ex"], task_id: "293", base_sha: nil)

      assert prompt =~ "Already on the target branch"
      assert prompt =~ "(unavailable)"
    end
  end

  describe "resolve/2" do
    test "reports no conflicted files after selecting a resolver" do
      AgentRegistry.reset()
      mark_installed(Codex, true)
      on_exit(fn -> AgentRegistry.reset() end)

      repo = GitFixture.init_repo(name: "resolver-no-conflict")
      worktree = %Worktree{id: "wt", path: repo, branch: "harness/wt", repo: repo, base_sha: "base"}

      assert Resolver.resolve(worktree, implementer: "claude", reviewer: "codex", task_id: "293") ==
               {:error, :no_conflicted_files}
    end
  end

  @spec mark_installed(module(), boolean()) :: :ok
  defp mark_installed(module, installed?) do
    :sys.replace_state(AgentRegistry, fn state -> put_in(state, [:installed, module], installed?) end)
    :ok
  end

  @spec mark_all_installed(boolean()) :: :ok
  defp mark_all_installed(installed?) do
    Enum.each(AgentRegistry.agents(), fn {_agent, module} -> mark_installed(module, installed?) end)
  end
end
