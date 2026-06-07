defmodule Harness.FakeAdapter do
  @moduledoc false

  # A process-spawning fake `Harness.AgentAdapter` for the behaviour, OSProcess,
  # and Driver suites — and live proof the contract is implementable in a
  # handful of lines. Each `build_command/1` branch spawns a shell builtin so
  # capture, termination, and the two timeout paths can be exercised
  # deterministically without a real coding agent. Select a branch with
  # `adapter_opts: [command: ...]`; the default is `:echo`.

  use Harness.AgentAdapter

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation

  @impl AgentAdapter
  def capabilities do
    %Capabilities{session_resume: true, permission_modes: [:autonomous, :plan]}
  end

  @impl AgentAdapter
  def rule_channel, do: :none

  @impl AgentAdapter
  def build_command(%Invocation{permission_mode: mode, adapter_opts: opts} = invocation) do
    # Mirror a real adapter: a permission mode outside capabilities/0 is a
    # build_command error, never a silent fallback (the conformance contract).
    if mode in capabilities().permission_modes do
      with {:ok, invocation} <- AgentAdapter.attach_rules(__MODULE__, invocation) do
        {exe, argv, _} = command(command_for(invocation, opts), invocation)
        {:ok, {exe, argv, Map.to_list(invocation.env)}}
      end
    else
      {:error, {:unsupported_permission_mode, mode}}
    end
  end

  # :echo            — emits one line, exits 0.
  # {:echo, text}    — emits `text` as one argv element (argv-verbatim fixture,
  #                    Task 23): proves an argument reaches the agent free of
  #                    shell word-splitting, globbing, or expansion.
  # :stdin_eof       — reads stdin, then emits a marker (stdin-EOF fixture,
  #                    Task 23): a raw OTP-port stdin would stall it forever.
  # :write           — writes a file into cwd (the worktree), exits 0 — a run
  #                    that produced a real diff to commit.
  # :snapshot_worktree
  #                  — records cwd's file listing at agent run time
  #                    (provisioning-order fixture): a check grepping that
  #                    snapshot proves the check-stack setup ran before the
  #                    agent spawned.
  # :write_then_hang — writes a file into cwd, then idles emitting nothing — a
  #                    timed-out agent that still left work to commit + grade.
  # :break_git       — overwrites the worktree's .git pointer, so the harness
  #                    commit step fails (the commit-failure fixture).
  # :detach_head     — writes a file into cwd then detaches HEAD at the run
  #                    branch tip (HEAD-moved fixture): proves commit/2 losslessly
  #                    re-attaches HEAD to the branch and lands the deliverable
  #                    rather than stranding it (the reconcile-on-commit path).
  # {:write_then_wait_for_file, path}
  #                  — writes a file, then waits until path exists (batch cap fixture).
  # {:write_status_by_task, red_ids}
  #                  — writes a status file that fails checks for listed task ids.
  # :sleep           — stays alive emitting nothing (idle-timeout fixture).
  # :exit_code       — exits 3 with no output (advisory exit-status fixture).
  # :burst           — emits across pauses each shorter than a test idle window
  #                    (idle-reset fixture); the whole run outlasts that window.
  # :flood           — emits forever (total-timeout fixture; idle keeps resetting).
  # :missing         — an executable not on PATH (invoke-failure fixture).
  # :repair_noop     — churns a committable file but never satisfies a marker
  #                    check, so verification stays red — the red-implementer
  #                    fixture the reviewer-path tests build on.
  # :operator_steer  — first run writes attempt.txt; resumed run records the
  #                    operator steer prompt into operator_steer_marker.
  # :write_and_pollute_checkout
  #                  — writes into cwd and the main checkout, so pollution-skip
  #                    tests still have worktree changes to commit.
  # :move_cwd_aside    — writes a file, then moves cwd out of the way before
  #                    commit (missing-worktree fixture).
  # {:write_sibling_and_move_cwd, path}
  #                  — writes into a sibling worktree, then makes cwd disappear
  #                    (cross-worktree write regression fixture).
  #
  # Reviewer doubles (the agent-gate workflow's THE-gate fixtures) — each
  # writes the .harness/review.json verdict artifact harness reads mechanically:
  # {:review, verdict}        — writes ONLY the artifact (zero reviewer diff —
  #                             the first-attempt-pass fixture).
  # {:review_with_fix, verdict}
  #                           — writes a fix file then the artifact (nonzero
  #                             reviewer diff — the reviewer-fixed-it fixture).
  # {:review_capture_prompt, verdict}
  #                           — records the reviewer prompt into
  #                             reviewer_prompt.txt, then writes the artifact.
  # :review_malformed         — writes invalid JSON to the artifact path (the
  #                             review-stuck fixture).
  # {:review_by_task, reject_ids}
  #                           — rejects the listed item ids, approves the rest
  #                             (per-task verdict fixture for batch tests; the
  #                             reviewer invocation's task_id is "<id>-review").
  # {:review_if_file, path}   — approves when the implementer left `path` in the
  #                             worktree; otherwise reports stuck in prose and
  #                             writes NO artifact (the batch fail-over fixture:
  #                             empty implementer diff → review_stuck).
  # {:review_verdict_by_file, path}
  #                           — approves when `path` exists, rejects otherwise —
  #                             always writes the artifact (per-implementer
  #                             verdict fixture for A/B comparison tests).
  #
  # Recovery doubles (bounded `.harness/recovery.json` seam fixtures) — selected
  # with `recovery_command:` when the invocation task id ends in "-recovery":
  # :recovery_clean       — moves `$HARNESS_RECOVERY_REPO/leaked.txt` into the
  #                         worktree artifact directory and
  #                         writes a repaired artifact.
  # :recovery_dead        — writes a dead artifact.
  #
  # Audit doubles (post-merge audit agent fixtures):
  # {:audit, short_sha}       — writes `.audit/<short_sha>.md` + the uncommitted
  #                             `.harness/audit.json` summary, then commits the
  #                             report as `audit(<short_sha>): ...` (the
  #                             audited-and-pushed fixture). Audit harness reads
  #                             the JSON best-effort and ff-pushes the commit.
  # {:audit_capture_prompt, short_sha}
  #                  — records the audit prompt into the committed
  #                    `.audit/<short_sha>.md`, so a test can read the prompt
  #                    back off origin after the ff-push (the audit-prompt
  #                    content fixture). The prompt rides as a positional
  #                    parameter ($2), never interpolated into the script.
  defp command_for(%Invocation{task_id: task_id}, opts) when is_binary(task_id) do
    if String.ends_with?(task_id, "-recovery") do
      Keyword.get(opts, :recovery_command, Keyword.get(opts, :command, :echo))
    else
      Keyword.get(opts, :command, :echo)
    end
  end

  defp command_for(_invocation, opts), do: Keyword.get(opts, :command, :echo)

  defp command(:recovery_clean, _invocation) do
    json = Jason.encode!(%{outcome: "repaired", report: "cleaned fake checkout leak", repaired: "removed leaked.txt"})

    script =
      ~S|mkdir -p .harness; if [ -f "$HARNESS_RECOVERY_REPO/leaked.txt" ]; then mv "$HARNESS_RECOVERY_REPO/leaked.txt" .harness/recovered-leaked.txt; fi; printf '%s' "$1" > .harness/recovery.json|

    {"/bin/sh", ["-c", script, "harness-fake", json], []}
  end

  defp command(:recovery_dead, _invocation) do
    json = Jason.encode!(%{outcome: "dead", report: "fake recovery declared dead", repaired: nil})
    {"/bin/sh", ["-c", ~S|mkdir -p .harness; printf '%s' "$1" > .harness/recovery.json|, "harness-fake", json], []}
  end

  defp command({:audit_capture_prompt, short_sha}, %Invocation{prompt: prompt}) when is_binary(short_sha) do
    script =
      ~S|mkdir -p .audit; printf '%s' "$2" > ".audit/$1.md"; | <>
        ~S|git add .audit; git -c user.email=audit@fake -c user.name=fake-audit commit -q -m "audit($1): captured prompt"|

    {"/bin/sh", ["-c", script, "harness-fake", short_sha, prompt], []}
  end

  defp command({:audit, short_sha}, _invocation) when is_binary(short_sha) do
    script =
      ~S|mkdir -p .audit .harness; echo "clean - fake audit" > ".audit/$1.md"; | <>
        ~S|printf '{"findings": 0, "fixed": 0, "report": "clean"}' > .harness/audit.json; | <>
        ~S|git add .audit; git -c user.email=audit@fake -c user.name=fake-audit commit -q -m "audit($1): fake hygiene pass"|

    {"/bin/sh", ["-c", script, "harness-fake", short_sha], []}
  end

  defp command({:review_verdict_by_file, path}, _invocation) when is_binary(path) do
    script =
      ~S(mkdir -p .harness; if [ -f "$3" ]; then printf '%s' "$1"; else printf '%s' "$2"; fi > .harness/review.json)

    {"/bin/sh", ["-c", script, "harness-fake", review_json("approve"), review_json("reject"), path], []}
  end

  defp command({:review_by_task, reject_ids}, %Invocation{task_id: task_id}) when is_list(reject_ids) do
    item_id = String.replace_suffix(task_id, "-review", "")
    verdict = if item_id in reject_ids, do: "reject", else: "approve"
    command({:review, verdict}, nil)
  end

  defp command({:review_if_file, path}, _invocation) when is_binary(path) do
    script =
      ~S(if [ -f "$2" ]; then mkdir -p .harness; printf '%s' "$1" > .harness/review.json; ) <>
        ~S(else echo "STUCK: the implementer produced no work to review"; fi)

    {"/bin/sh", ["-c", script, "harness-fake", review_json("approve"), path], []}
  end

  defp command({:review, verdict}, _invocation) when verdict in ["approve", "reject"] do
    {"/bin/sh",
     ["-c", ~S(mkdir -p .harness; printf '%s' "$1" > .harness/review.json), "harness-fake", review_json(verdict)], []}
  end

  # {:review_miss_then, verdict}
  #   — first invocation leaves an (excluded) `.harness/` marker and writes NO
  #     artifact (the missing-verdict miss); the second invocation, seeing the
  #     marker, writes the verdict. Drives the Task-203 missing -> re-prompt ->
  #     verdict recovery path with one real miss followed by a real verdict.
  defp command({:review_miss_then, verdict}, _invocation) when verdict in ["approve", "reject"] do
    script =
      ~S(mkdir -p .harness; if [ -f .harness/.reprompt-marker ]; then printf '%s' "$1" > .harness/review.json; ) <>
        ~S(else : > .harness/.reprompt-marker; fi)

    {"/bin/sh", ["-c", script, "harness-fake", review_json(verdict)], []}
  end

  # {:review_malformed_then, verdict}
  #   — first invocation writes a MALFORMED verdict (invalid JSON) and leaves the
  #     (excluded) marker; the second invocation, seeing the marker, writes the
  #     valid verdict. Drives the Task-228 malformed -> re-prompt -> verdict
  #     recovery path (the malformed analogue of {:review_miss_then, _}).
  defp command({:review_malformed_then, verdict}, _invocation) when verdict in ["approve", "reject"] do
    script =
      ~S(mkdir -p .harness; if [ -f .harness/.reprompt-marker ]; then printf '%s' "$1" > .harness/review.json; ) <>
        ~S(else : > .harness/.reprompt-marker; echo '{not json' > .harness/review.json; fi)

    {"/bin/sh", ["-c", script, "harness-fake", review_json(verdict)], []}
  end

  # {:review_count_then, behavior}
  #   — appends one byte to the (excluded) `.harness/.invoke-count` on EVERY
  #     invocation so a test can count reviewer passes off the retained
  #     worktree, then performs `behavior`: `:miss` writes no artifact (a
  #     persistent miss — proves the Task-203 re-prompt fires exactly once,
  #     count == 2), `:malformed` writes invalid JSON (since Task 228 a malformed
  #     verdict re-prompts on the same path, so this also reaches count == 2).
  defp command({:review_count_then, behavior}, _invocation) when behavior in [:miss, :malformed] do
    tail =
      case behavior do
        :miss -> ""
        :malformed -> ~S(; echo '{not json' > .harness/review.json)
      end

    {"/bin/sh", ["-c", ~S(mkdir -p .harness; printf x >> .harness/.invoke-count) <> tail], []}
  end

  # {:review_fix_miss_then, verdict}
  #   — first invocation commits a real fix (`reviewer_fix.txt`) + leaves the
  #     (excluded) marker but writes NO verdict (the fix-then-exit miss); the
  #     second invocation, seeing the marker, writes the verdict without further
  #     fixes. Drives the Task-203 KPI check: the fix-diff baseline stays the
  #     implementer's SHA across the re-prompt, so the first pass's committed fix
  #     is still counted (a recomputed-at-retry baseline would report 0).
  defp command({:review_fix_miss_then, verdict}, _invocation) when verdict in ["approve", "reject"] do
    script =
      ~S(mkdir -p .harness; if [ -f .harness/.reprompt-marker ]; then printf '%s' "$1" > .harness/review.json; ) <>
        ~S(else : > .harness/.reprompt-marker; printf 'reviewer-fix\n' > reviewer_fix.txt; fi)

    {"/bin/sh", ["-c", script, "harness-fake", review_json(verdict)], []}
  end

  defp command({:review_with_fix, verdict}, _invocation) when verdict in ["approve", "reject"] do
    script = ~S(echo reviewer-fix > reviewer_fix.txt; mkdir -p .harness; printf '%s' "$1" > .harness/review.json)
    {"/bin/sh", ["-c", script, "harness-fake", review_json(verdict)], []}
  end

  defp command({:review_capture_prompt, verdict}, %Invocation{prompt: prompt}) when verdict in ["approve", "reject"] do
    script = ~S(printf '%s' "$1" > reviewer_prompt.txt; mkdir -p .harness; printf '%s' "$2" > .harness/review.json)
    {"/bin/sh", ["-c", script, "harness-fake", prompt, review_json(verdict)], []}
  end

  defp command(:review_malformed, _invocation) do
    {"/bin/sh", ["-c", ~S(mkdir -p .harness; echo '{not json' > .harness/review.json)], []}
  end

  defp command({:write_and_pollute_checkout, repo}, _invocation) when is_binary(repo) do
    path = shell_arg(Path.join(repo, "leaked.txt"))
    {"/bin/sh", ["-c", "echo agent-output > agent_output.txt; echo leaked > #{path}"], []}
  end

  defp command({:write_sibling_and_move_cwd, sibling}, _invocation) when is_binary(sibling) do
    target = shell_arg(Path.join(sibling, "foreign.txt"))

    {"/bin/sh",
     [
       "-c",
       "echo foreign > #{target}; echo agent-output > agent_output.txt; parent=$(dirname \"$PWD\"); base=$(basename \"$PWD\"); cd \"$parent\"; mv \"$base\" \"$base-gone\""
     ], []}
  end

  defp command(:echo, _invocation), do: {"/bin/echo", ["harness-test"], []}

  defp command({:echo, text}, _invocation) when is_binary(text), do: {"/bin/echo", [text], []}

  defp command(:stdin_eof, _invocation), do: {"/bin/sh", ["-c", "cat; echo stdin-eof-ok"], []}

  defp command(:write, _invocation), do: {"/bin/sh", ["-c", "echo agent-output > agent_output.txt"], []}

  # :capture_model — records invocation.model into a committed file (model-pin
  #                  threading fixture, Task 240): proves the run threads the
  #                  task's requested_model onto the agent Invocation, so the
  #                  adapter's `--model` flag is actually set. The model rides as
  #                  a positional parameter ($1), empty string when unpinned.
  # :capture_github_env
  #                — records the spawned process' GitHub auth/config env. Used
  #                  by agent-gate regressions proving in-run agents get no
  #                  ambient GitHub credentials.
  defp command(:capture_model, %Invocation{model: model}),
    do: {"/bin/sh", ["-c", ~S(printf '%s' "$1" > agent_model.txt), "harness-fake", model || ""], []}

  defp command(:capture_github_env, _invocation) do
    script =
      ~S(printf 'GH_TOKEN=%s\nGITHUB_TOKEN=%s\nGH_CONFIG_DIR=%s\n' "$GH_TOKEN" "$GITHUB_TOKEN" "$GH_CONFIG_DIR" > agent_github_env.txt)

    {"/bin/sh", ["-c", script], []}
  end

  defp command(:snapshot_worktree, _invocation), do: {"/bin/sh", ["-c", "ls > agent-saw.txt"], []}

  defp command(:write_then_hang, _invocation),
    do: {"/bin/sh", ["-c", "echo agent-output > agent_output.txt; sleep 30"], []}

  defp command(:break_git, _invocation), do: {"/bin/sh", ["-c", "echo broken > .git"], []}

  defp command(:detach_head, _invocation),
    do: {"/bin/sh", ["-c", "echo agent-output > agent_output.txt; git checkout -q --detach"], []}

  defp command(:move_cwd_aside, _invocation),
    do:
      {"/bin/sh",
       [
         "-c",
         ~s{echo agent-output > agent_output.txt; parent=$(dirname "$PWD"); base=$(basename "$PWD"); cd "$parent"; mv "$base" "$base-gone"}
       ], []}

  defp command({:write_then_wait_for_file, path}, _invocation) when is_binary(path) do
    # Task 70: self-terminate if reparented to init (PPID=1). Without this,
    # a test crash or Ctrl-C before the gate file is written leaves this
    # shell polling the gate forever (Port owner death does not always
    # SIGTERM a child that neither reads nor writes its pipes).
    arg = shell_arg(path)

    script =
      "echo agent-output > agent_output.txt; " <>
        "while [ ! -f #{arg} ]; do " <>
        ~s{if [ "$(ps -o ppid= -p $$ | tr -d ' ')" = "1" ]; then exit 1; fi; } <>
        "sleep 0.05; done"

    {"/bin/sh", ["-c", script], []}
  end

  defp command({:write_status_by_task, red_ids}, %Invocation{task_id: task_id}) when is_list(red_ids) do
    status = if task_id in red_ids, do: "fail", else: "pass"
    {"/bin/sh", ["-c", "echo agent-output > agent_output.txt; echo #{status} > status.txt"], []}
  end

  defp command(:sleep, _invocation), do: {"/bin/sleep", ["30"], []}

  defp command(:exit_code, _invocation), do: {"/bin/sh", ["-c", "exit 3"], []}

  defp command(:burst, _invocation), do: {"/bin/sh", ["-c", "echo one; sleep 0.2; echo two; sleep 0.2; echo three"], []}

  defp command(:flood, _invocation), do: {"/bin/sh", ["-c", "while true; do echo tick; sleep 0.05; done"], []}

  defp command(:missing, _invocation), do: {"definitely-not-a-real-binary-xyz", [], []}

  defp command(:repair_noop, _invocation), do: {"/bin/sh", ["-c", "echo churn >> churn.txt"], []}

  # The prompt rides as a positional parameter ($1), never interpolated into the
  # script, so a prompt of any bytes reaches the marker file unmangled.
  defp command(:operator_steer, %Invocation{session: :resume, prompt: prompt}),
    do:
      {"/bin/sh",
       ["-c", ~S(echo agent-output > agent_output.txt; printf '%s' "$1" > operator_steer_marker), "harness-fake", prompt],
       []}

  defp command(:operator_steer, %Invocation{session: nil}),
    do: {"/bin/sh", ["-c", "sleep 0.3; echo first-attempt > attempt.txt"], []}

  defp shell_arg(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  # The verdict artifact the reviewer doubles write — fixed report/ratings so
  # tests can assert on the persisted values.
  @doc false
  @spec review_ratings() :: %{optional(String.t()) => integer()}
  def review_ratings do
    %{"performance" => 8, "truthfulness" => 9, "code_quality" => 7, "idiom" => 8}
  end

  @doc false
  @spec review_report(String.t()) :: String.t()
  def review_report(verdict), do: "fake review: #{verdict}"

  defp review_json(verdict) do
    Jason.encode!(%{verdict: verdict, report: review_report(verdict), ratings: review_ratings()})
  end
end
