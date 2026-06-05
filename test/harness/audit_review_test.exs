defmodule Harness.AuditReviewTest do
  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Outcome
  alias Harness.AuditReview

  # Generous ceilings for the end-to-end dispatch tests below. Each spawns a
  # real, fast-exiting grader subprocess (/bin/echo, /bin/sh), so the only way
  # the idle window trips is OS-level subprocess scheduling starvation under the
  # full async suite — not a slow command. Wide headroom keeps these
  # deterministic (one such test flaked a harness grading run with
  # `{:timed_out, :idle}` + empty output) without weakening any assertion: the
  # run still must emit its sentinel and exit. The dedicated idle-timeout test
  # keeps its own tight `idle_timeout: 150`.
  @dispatch_total_timeout 30_000
  @dispatch_idle_timeout 20_000

  describe "extract_verdict/1" do
    test "returns :approve when only the approve sentinel appears" do
      assert AuditReview.extract_verdict("...analysis...\n<<<VERDICT:APPROVE>>>") == :approve
    end

    test "returns :reject when only the reject sentinel appears" do
      assert AuditReview.extract_verdict("...analysis...\n<<<VERDICT:REJECT>>>") == :reject
    end

    test "returns :unclear when no sentinel appears" do
      assert AuditReview.extract_verdict("I think the fix is fine, but I'm not sure.") == :unclear
    end

    test "returns :unclear on empty output" do
      assert AuditReview.extract_verdict("") == :unclear
    end

    test "last-match wins when both sentinels appear — approve later" do
      output = """
      Considered REJECT because of X.
      <<<VERDICT:REJECT>>>
      But on reflection, X is fine.
      <<<VERDICT:APPROVE>>>
      """

      assert AuditReview.extract_verdict(output) == :approve
    end

    test "last-match wins when both sentinels appear — reject later" do
      output = """
      Considered APPROVE because of X.
      <<<VERDICT:APPROVE>>>
      But on reflection, Y is broken.
      <<<VERDICT:REJECT>>>
      """

      assert AuditReview.extract_verdict(output) == :reject
    end

    test "tolerates sentinel embedded in JSON envelope" do
      # Simulates raw NDJSON from a stream-json adapter where the sentinel
      # appears inside a "text" field.
      output = ~s({"type":"assistant","content":[{"text":"...<<<VERDICT:APPROVE>>>"}]})
      assert AuditReview.extract_verdict(output) == :approve
    end

    test "tolerates sentinel surrounded by markdown" do
      assert AuditReview.extract_verdict("**<<<VERDICT:REJECT>>>**") == :reject
    end
  end

  describe "default_grader/1" do
    test "auto-pairs :claude to the Codex adapter module" do
      assert {:ok, Harness.AgentAdapter.Codex} = AuditReview.default_grader(:claude)
    end

    test "auto-pairs :codex to the Claude adapter module" do
      assert {:ok, Harness.AgentAdapter.Claude} = AuditReview.default_grader(:codex)
    end

    test "returns :no_default_grader for implementers without an auto-pair" do
      for impl <- [:grok, :cursor, :antigravity, :pi] do
        assert {:error, {:no_default_grader, ^impl}} = AuditReview.default_grader(impl)
      end
    end
  end

  describe "grade_fix/1 — option validation" do
    test "rejects missing :implementer" do
      assert {:error, {:missing_option, :implementer}} =
               AuditReview.grade_fix(sha: "abc", prompt: "review")
    end

    test "rejects missing :sha" do
      assert {:error, {:missing_option, :sha}} =
               AuditReview.grade_fix(implementer: :claude, prompt: "review")
    end

    test "rejects missing :prompt" do
      assert {:error, {:missing_option, :prompt}} =
               AuditReview.grade_fix(implementer: :claude, sha: "abc")
    end

    test "rejects empty :sha" do
      assert {:error, {:invalid_option, :sha, ""}} =
               AuditReview.grade_fix(implementer: :claude, sha: "", prompt: "review")
    end

    test "rejects empty :prompt" do
      assert {:error, {:invalid_option, :prompt, ""}} =
               AuditReview.grade_fix(implementer: :claude, sha: "abc", prompt: "")
    end

    test "rejects non-atom :implementer" do
      assert {:error, {:invalid_option, :implementer, "claude"}} =
               AuditReview.grade_fix(implementer: "claude", sha: "abc", prompt: "review")
    end

    test "rejects non-atom :grader" do
      assert {:error, {:invalid_option, :grader, "codex"}} =
               AuditReview.grade_fix(
                 implementer: :claude,
                 grader: "codex",
                 sha: "abc",
                 prompt: "review"
               )
    end
  end

  describe "grade_fix/1 — grader resolution" do
    test "returns :no_default_grader for implementers without an auto-pair (:grok)" do
      assert {:error, {:no_default_grader, :grok}} =
               AuditReview.grade_fix(implementer: :grok, sha: "abc", prompt: "review")
    end

    test "returns :no_default_grader for implementers without an auto-pair (:cursor)" do
      assert {:error, {:no_default_grader, :cursor}} =
               AuditReview.grade_fix(implementer: :cursor, sha: "abc", prompt: "review")
    end

    test "rejects unknown :grader atom" do
      assert {:error, {:unknown_agent, :imaginary}} =
               AuditReview.grade_fix(
                 implementer: :claude,
                 grader: :imaginary,
                 sha: "abc",
                 prompt: "review"
               )
    end
  end

  describe "grade_fix/1 — end-to-end dispatch" do
    # Reflex fingerprints invocation.cwd at spawn — /tmp is huge on macOS and
    # stalls the driver before the fast /bin/echo fixture can finish.
    setup do
      cwd = Path.join(System.tmp_dir!(), "audit-review-dispatch-#{System.unique_integer([:positive])}")
      File.mkdir_p!(cwd)
      on_exit(fn -> File.rm_rf!(cwd) end)
      %{cwd: cwd}
    end

    test "extracts :approve verdict from a grader that emits the approve sentinel", %{cwd: cwd} do
      assert {:ok, %{verdict: :approve, outcome: %Outcome{kind: :exited}, grader: Harness.FakeAdapter}} =
               AuditReview.grade_fix(
                 implementer: :claude,
                 grader: Harness.FakeAdapter,
                 sha: "abc1234",
                 prompt: "review this fix",
                 cwd: cwd,
                 adapter_opts: [command: {:echo, "<<<VERDICT:APPROVE>>>"}],
                 total_timeout: @dispatch_total_timeout,
                 idle_timeout: @dispatch_idle_timeout
               )
    end

    test "extracts :reject verdict from a grader that emits the reject sentinel", %{cwd: cwd} do
      assert {:ok, %{verdict: :reject, outcome: %Outcome{kind: :exited}}} =
               AuditReview.grade_fix(
                 implementer: :claude,
                 grader: Harness.FakeAdapter,
                 sha: "abc1234",
                 prompt: "review this fix",
                 cwd: cwd,
                 adapter_opts: [command: {:echo, "<<<VERDICT:REJECT>>>"}],
                 total_timeout: @dispatch_total_timeout,
                 idle_timeout: @dispatch_idle_timeout
               )
    end

    test "returns :unclear verdict on idle timeout with no sentinel" do
      # Isolated cwd — /tmp's churn resets the reflex progress fingerprint and
      # starves the idle watchdog under a shared directory (DriverTest uses the
      # same unique-tmp pattern for :sleep).
      cwd = Path.join(System.tmp_dir!(), "harness-audit-idle-#{System.unique_integer([:positive])}")
      File.mkdir_p!(cwd)

      assert {:ok, %{verdict: :unclear, outcome: %Outcome{kind: {:timed_out, :idle}}}} =
               AuditReview.grade_fix(
                 implementer: :claude,
                 grader: Harness.FakeAdapter,
                 sha: "abc1234",
                 prompt: "review this fix",
                 cwd: cwd,
                 adapter_opts: [command: :sleep],
                 total_timeout: 10_000,
                 idle_timeout: 150
               )
    end

    test "returns :unclear verdict on completed run with no sentinel", %{cwd: cwd} do
      assert {:ok, %{verdict: :unclear, outcome: %Outcome{kind: :exited}}} =
               AuditReview.grade_fix(
                 implementer: :claude,
                 grader: Harness.FakeAdapter,
                 sha: "abc1234",
                 prompt: "review this fix",
                 cwd: cwd,
                 adapter_opts: [command: :echo],
                 total_timeout: @dispatch_total_timeout,
                 idle_timeout: @dispatch_idle_timeout
               )
    end

    test "synthetic task_id includes the sha", %{cwd: cwd} do
      # The FakeAdapter doesn't expose task_id in its output, but build_invocation
      # is a private helper — assert indirectly that dispatch with a sha succeeds
      # (proves the Invocation was built with a non-empty task_id, which is
      # required by Invocation's @enforce_keys).
      assert {:ok, %{verdict: :approve}} =
               AuditReview.grade_fix(
                 implementer: :claude,
                 grader: Harness.FakeAdapter,
                 sha: "deadbeef",
                 prompt: "review",
                 cwd: cwd,
                 adapter_opts: [command: {:echo, "<<<VERDICT:APPROVE>>>"}],
                 total_timeout: @dispatch_total_timeout,
                 idle_timeout: @dispatch_idle_timeout
               )
    end

    test "propagates {:error, _} when Driver.run fails to spawn", %{cwd: cwd} do
      # FakeAdapter's :missing fixture points to a non-existent executable;
      # Driver.run returns {:error, _} before spawning, and the with-chain
      # in grade_fix/1 must propagate it instead of producing an {:ok, _}.
      assert {:error, _reason} =
               AuditReview.grade_fix(
                 implementer: :claude,
                 grader: Harness.FakeAdapter,
                 sha: "abc1234",
                 prompt: "review",
                 cwd: cwd,
                 adapter_opts: [command: :missing],
                 total_timeout: @dispatch_total_timeout,
                 idle_timeout: @dispatch_idle_timeout
               )
    end

    test "threads :cwd through to the grader invocation" do
      # FakeAdapter's :write fixture writes agent_output.txt into the
      # invocation's cwd. Asserting the file lands in our tmp dir proves
      # the :cwd opt was forwarded into Invocation.cwd and honored by the
      # spawned process.
      tmp_dir = Path.join(System.tmp_dir!(), "audit-review-cwd-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      assert {:ok, %{outcome: %Outcome{kind: :exited}}} =
               AuditReview.grade_fix(
                 implementer: :claude,
                 grader: Harness.FakeAdapter,
                 sha: "abc1234",
                 prompt: "review",
                 cwd: tmp_dir,
                 adapter_opts: [command: :write],
                 total_timeout: @dispatch_total_timeout,
                 idle_timeout: @dispatch_idle_timeout
               )

      assert File.exists?(Path.join(tmp_dir, "agent_output.txt"))
    end
  end
end
