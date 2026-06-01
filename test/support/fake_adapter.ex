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
        {exe, argv, _} = command(Keyword.get(opts, :command, :echo), invocation)
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
  # :write_then_hang — writes a file into cwd, then idles emitting nothing — a
  #                    timed-out agent that still left work to commit + grade.
  # :break_git       — overwrites the worktree's .git pointer, so the harness
  #                    commit step fails (the commit-failure fixture).
  # :detach_head     — writes a file into cwd then detaches HEAD off the run
  #                    branch (HEAD-moved fixture for Task 30): proves the
  #                    commit step refuses to land work on a moved HEAD rather
  #                    than stranding the deliverable.
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
  # :repair          — repair-loop happy path: the first run (session nil)
  #                    writes attempt.txt and no repair_marker, so a check that
  #                    requires repair_marker grades red; the resumed run
  #                    (session :resume) writes repair_marker, filling it with
  #                    the repair prompt it was handed so a test can assert the
  #                    failing checks were fed back.
  # :repair_noop     — every run churns a committable file but never writes
  #                    repair_marker, so verification stays red — drives the
  #                    repair loop to its attempt cap.
  # :repair_quota    — the first run writes a diff; the resumed run does nothing,
  #                    settling :no_changes — a non-repairable failure (a
  #                    quota-starved agent) that must end the loop, not burn
  #                    every remaining attempt.
  # :repair_quota_with_output
  #                  — the first run writes a diff; the resumed run writes a
  #                    different diff while emitting quota text, so the repair
  #                    loop must classify the transcript instead of relying on
  #                    the no-diff short-circuit.
  # :sampled_repair  — first run emits a witness-visible line, waits briefly,
  #                    then writes a diff; resumed run records the repair prompt.
  # :write_and_pollute_checkout
  #                  — writes into cwd and the main checkout, so pollution-skip
  #                    tests still have worktree changes to commit.
  # :move_cwd_aside    — writes a file, then moves cwd out of the way before
  #                    commit (missing-worktree fixture).
  # {:write_sibling_and_move_cwd, path}
  #                  — writes into a sibling worktree, then makes cwd disappear
  #                    (cross-worktree write regression fixture).
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

  # The prompt rides as a positional parameter ($1), never interpolated into the
  # script, so a repair prompt of any bytes reaches repair_marker unmangled.
  defp command(:repair, %Invocation{session: :resume, prompt: prompt}),
    do: {"/bin/sh", ["-c", ~S(printf '%s' "$1" > repair_marker), "harness-fake", prompt], []}

  defp command(:repair, %Invocation{session: nil}), do: {"/bin/sh", ["-c", "echo first-attempt > attempt.txt"], []}

  defp command(:repair_noop, _invocation), do: {"/bin/sh", ["-c", "echo churn >> churn.txt"], []}

  defp command(:repair_quota, %Invocation{session: :resume}), do: {"/bin/echo", ["repair-did-nothing"], []}

  defp command(:repair_quota, %Invocation{session: nil}), do: {"/bin/sh", ["-c", "echo first-attempt > attempt.txt"], []}

  defp command(:repair_quota_with_output, %Invocation{session: :resume}),
    do: {"/bin/sh", ["-c", "echo churn >> churn.txt; echo subscription quota exhausted"], []}

  defp command(:repair_quota_with_output, %Invocation{session: nil}),
    do: {"/bin/sh", ["-c", "echo first-attempt > attempt.txt"], []}

  defp command(:sampled_repair, %Invocation{session: :resume, prompt: prompt}),
    do: {"/bin/sh", ["-c", ~S(printf '%s' "$1" > repair_marker), "harness-fake", prompt], []}

  defp command(:sampled_repair, %Invocation{session: nil}),
    do: {"/bin/sh", ["-c", "echo witness-line; sleep 0.25; echo agent-output > agent_output.txt; sleep 0.25"], []}

  defp shell_arg(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
