defmodule Harness.CorpusGradingTest do
  @moduledoc """
  End-to-end proof of the agent-evaluation corpus grading pattern (Task 151).

  Builds a corpus-shaped throwaway repo with one Mode-A and one Mode-B task and
  grades it through `Harness.Verification.run/2`, exercising the new
  verification-only `inject` step (`Harness.CheckStack` `:inject`). No live agent
  is involved: the "agent's solution" is written deterministically so the test
  asserts the *grading mechanism*, not any agent's skill.

  ## The two modes

    * **Mode A (visible spec / TDD).** The grading test ships in the corpus repo;
      the agent makes it pass. Measures implementation skill on a known surface.
    * **Mode B (hidden grader / unfamiliar library).** The corpus repo ships only
      a vendored library with a deliberately non-idiomatic API (`Vault.fetch/2`
      returns `{:found, v} | :absent`, not `{:ok, v} | :error`) and a skeleton to
      fill in. The grading test is **withheld** from the agent's worktree and
      copied in from a host-side answer key by an `inject` command, only at
      verification time. An agent that hallucinates the idiomatic return shape
      instead of reading `vault.ex` fails the hidden grader — that is the
      un-gameable signal Mode B measures.

  The grading checks run `elixir` directly (no `mix`), so the suite stays fast
  and dependency-free while still proving the injection-and-grade lifecycle.
  """

  use ExUnit.Case, async: true

  alias Harness.CheckStack
  alias Harness.GitFixture
  alias Harness.Verification
  alias Harness.Verification.Check
  alias Harness.Verification.Verdict

  # ── Mode A: a visible-spec task. Grader ships in the corpus repo. ───────────
  @mode_a_skeleton """
  defmodule Counter do
    @moduledoc "Mode-A skeleton: implement inc/1 so the in-repo grader passes."
    def inc(n), do: n + 1
  end
  """

  @mode_a_grader """
  # Mode-A grader — ships in the corpus repo (the agent sees this).
  defmodule ModeAGrader do
    def run do
      2 = Counter.inc(1)
      42 = Counter.inc(41)
      IO.puts("mode-a OK")
    end
  end

  ModeAGrader.run()
  """

  # ── Mode B: a vendored "unfamiliar" library with a non-idiomatic API. ───────
  @vault_lib """
  defmodule Vault do
    @moduledoc "Vendored unfamiliar lib: a quirky in-memory key store."

    def new, do: %{__vault__: true, entries: %{}}

    # NOTE the non-idiomatic shape an agent must READ, not guess.
    def put(%{__vault__: true} = vault, key, value) do
      {:ok, %{vault | entries: Map.put(vault.entries, key, value)}}
    end

    def fetch(%{__vault__: true} = vault, key) do
      case Map.fetch(vault.entries, key) do
        {:ok, value} -> {:found, value}
        :error -> :absent
      end
    end
  end
  """

  @mode_b_skeleton_correct """
  defmodule VaultUser do
    @moduledoc "Mode-B skeleton: use Vault's non-idiomatic API correctly."

    def store_and_get(key, value) do
      {:ok, vault} = Vault.put(Vault.new(), key, value)

      case Vault.fetch(vault, key) do
        {:found, found} -> found
        :absent -> :missing
      end
    end
  end
  """

  # A plausible hallucination: assumes the idiomatic {:ok, v} / :error contract
  # instead of reading vault.ex. Compiles, looks right, fails the hidden grader.
  @mode_b_skeleton_hallucinated """
  defmodule VaultUser do
    @moduledoc "Mode-B skeleton: hallucinated idiomatic API."

    def store_and_get(key, value) do
      {:ok, vault} = Vault.put(Vault.new(), key, value)

      case Vault.fetch(vault, key) do
        {:ok, found} -> found
        :error -> :missing
      end
    end
  end
  """

  @mode_b_grader """
  # Mode-B HIDDEN grader — withheld from the agent's worktree, injected at
  # verification time. Asserts behavior the API shape forces the agent to read.
  defmodule ModeBGrader do
    def run do
      "v1" = VaultUser.store_and_get("k", "v1")
      "x" = VaultUser.store_and_get("other", "x")
      IO.puts("mode-b OK")
    end
  end

  ModeBGrader.run()
  """

  describe "corpus grading pattern (Mode A visible + Mode B hidden grader)" do
    test "both modes grade green; the hidden grader is injected only at verification time" do
      %{worktree: worktree} = build_corpus_repo(mode_b: @mode_b_skeleton_correct)

      assert {:ok, %Verdict{status: :pass, results: results}} =
               Verification.run(worktree, check_stack: corpus_stack(worktree))

      assert Enum.map(results, & &1.name) == ["mode-a", "mode-b"]
      assert Enum.all?(results, &(&1.status == :pass))
      # The hidden grader is present only after the inject step ran.
      assert File.exists?(Path.join(worktree, "grade_b.exs"))
    end

    test "the Mode-B hidden grader is withheld from the agent worktree (prepare/2)" do
      %{worktree: worktree} = build_corpus_repo(mode_b: @mode_b_skeleton_correct)

      assert :ok = Verification.prepare(worktree, check_stack: corpus_stack(worktree))

      # The agent starts with the vendored lib and the skeleton, but NEVER the
      # grading spec — the Mode-B isolation guarantee.
      assert File.exists?(Path.join(worktree, "lib/vault.ex"))
      assert File.exists?(Path.join(worktree, "lib/vault_user.ex"))
      refute File.exists?(Path.join(worktree, "grade_b.exs"))
    end

    test "a hallucinated Mode-B solution fails the hidden behavioral grader" do
      %{worktree: worktree} = build_corpus_repo(mode_b: @mode_b_skeleton_hallucinated)

      assert {:ok, %Verdict{status: :fail, results: results}} =
               Verification.run(worktree, check_stack: corpus_stack(worktree))

      # Mode A still passes; only the hidden Mode-B grader catches the
      # hallucinated API contract.
      assert %{"mode-a" => :pass, "mode-b" => :fail} =
               Map.new(results, &{&1.name, &1.status})
    end
  end

  # The corpus project's check stack: an `inject` step copies the withheld
  # Mode-B grader from the host answer key into the worktree right before the
  # grading checks, which run `elixir` against the corpus files.
  defp corpus_stack(worktree) do
    answer_key = Path.join(worktree, ".answer-key/grade_b.exs")

    %CheckStack{
      name: :corpus_elixir,
      inject: [check("inject-mode-b-grader", "cp", [answer_key, Path.join(worktree, "grade_b.exs")])],
      checks: [
        check("mode-a", "elixir", ["-r", "lib/counter.ex", "grade_a.exs"]),
        check("mode-b", "elixir", ["-r", "lib/vault.ex", "-r", "lib/vault_user.ex", "grade_b.exs"])
      ]
    }
  end

  # Lays out a corpus-shaped repo in a throwaway dir. The Mode-B grader lives in
  # `.answer-key/` — the host-side answer key the inject step reads — and is
  # deliberately NOT placed at the worktree root the grading check runs from, so
  # only `inject` (and never `prepare/2`) can put it where it grades.
  defp build_corpus_repo(opts) do
    worktree = GitFixture.tmp_base()
    File.mkdir_p!(Path.join(worktree, "lib"))
    File.mkdir_p!(Path.join(worktree, ".answer-key"))

    File.write!(Path.join(worktree, "lib/counter.ex"), @mode_a_skeleton)
    File.write!(Path.join(worktree, "grade_a.exs"), @mode_a_grader)
    File.write!(Path.join(worktree, "lib/vault.ex"), @vault_lib)
    File.write!(Path.join(worktree, "lib/vault_user.ex"), Keyword.fetch!(opts, :mode_b))
    File.write!(Path.join(worktree, ".answer-key/grade_b.exs"), @mode_b_grader)

    on_exit(fn -> File.rm_rf!(worktree) end)
    %{worktree: worktree}
  end

  defp check(name, command, args) do
    %Check{name: name, command: command, args: args}
  end
end
