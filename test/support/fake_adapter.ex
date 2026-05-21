defmodule Harness.FakeAdapter do
  @moduledoc false

  # A process-spawning fake `Harness.AgentAdapter` for the behaviour, OSProcess,
  # and Driver suites — and live proof the contract is implementable in a
  # handful of lines. Each `build_command/1` branch spawns a shell builtin so
  # capture, termination, and the two timeout paths can be exercised
  # deterministically without a real coding agent. Select a branch with
  # `adapter_opts: [command: ...]`; the default is `:echo`.

  @behaviour Harness.AgentAdapter

  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.OSProcess
  alias Harness.AgentAdapter.Run

  @impl Harness.AgentAdapter
  def capabilities do
    %Capabilities{session_resume: true, permission_modes: [:autonomous, :plan]}
  end

  @impl Harness.AgentAdapter
  def build_command(%Invocation{adapter_opts: opts}) do
    {:ok, command(Keyword.get(opts, :command, :echo))}
  end

  @impl Harness.AgentAdapter
  def classify_message({port, {:data, data}}, %Run{port: port} = run), do: {:output, data, run}

  def classify_message({port, {:exit_status, status}}, %Run{port: port} = run), do: {:terminated, run, status}

  def classify_message(_message, _run), do: :ignore

  @impl Harness.AgentAdapter
  def terminate(%Run{} = run), do: OSProcess.kill(run)

  # :echo            — emits one line, exits 0.
  # :write           — writes a file into cwd (the worktree), exits 0 — a run
  #                    that produced a real diff to commit.
  # :write_then_hang — writes a file into cwd, then idles emitting nothing — a
  #                    timed-out agent that still left work to commit + grade.
  # :break_git       — overwrites the worktree's .git pointer, so the harness
  #                    commit step fails (the commit-failure fixture).
  # :sleep           — stays alive emitting nothing (idle-timeout fixture).
  # :exit_code       — exits 3 with no output (advisory exit-status fixture).
  # :burst           — emits across pauses each shorter than a test idle window
  #                    (idle-reset fixture); the whole run outlasts that window.
  # :flood           — emits forever (total-timeout fixture; idle keeps resetting).
  # :missing         — an executable not on PATH (invoke-failure fixture).
  defp command(:echo), do: {"/bin/echo", ["harness-test"], []}

  defp command(:write), do: {"/bin/sh", ["-c", "echo agent-output > agent_output.txt"], []}

  defp command(:write_then_hang), do: {"/bin/sh", ["-c", "echo agent-output > agent_output.txt; sleep 30"], []}

  defp command(:break_git), do: {"/bin/sh", ["-c", "echo broken > .git"], []}

  defp command(:sleep), do: {"/bin/sleep", ["30"], []}
  defp command(:exit_code), do: {"/bin/sh", ["-c", "exit 3"], []}

  defp command(:burst), do: {"/bin/sh", ["-c", "echo one; sleep 0.2; echo two; sleep 0.2; echo three"], []}

  defp command(:flood), do: {"/bin/sh", ["-c", "while true; do echo tick; sleep 0.05; done"], []}

  defp command(:missing), do: {"definitely-not-a-real-binary-xyz", [], []}
end
