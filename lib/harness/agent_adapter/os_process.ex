defmodule Harness.AgentAdapter.OSProcess do
  @moduledoc """
  Shared lifecycle helpers for the OS process behind an adapter's OTP port.

  An adapter spawns its agent's headless CLI as an OS process connected to an
  OTP port (`Harness.AgentAdapter.invoke/2`). This module is the small,
  idempotent toolkit for the rest of that lifecycle — reading the OS pid,
  closing the port, draining stranded messages, and killing a run outright — so
  every adapter shares one correct implementation instead of re-deriving the
  `Port`/`kill` plumbing.

  `kill/1` SIGKILLs the immediate OS pid; tool subprocesses the agent itself
  spawned can be orphaned by that. The boot-time `Harness.Worktree.Sweeper` is
  the backstop for orphaned working directories.
  """

  alias Harness.AgentAdapter.Run

  @doc """
  The OS process id behind `port`, or `nil` once the port has closed.
  """
  @spec os_pid(port()) :: non_neg_integer() | nil
  def os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      nil -> nil
    end
  end

  @doc """
  Closes `port`, tolerating a port that has already closed.

  Idempotent: `Port.close/1` raises `ArgumentError` on an already-closed port,
  which races with the killed OS process closing it first — that race is
  swallowed.
  """
  @spec close(port()) :: :ok
  def close(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Drains any `{port, _}` messages still queued in the caller's mailbox.

  Called after a kill so stale port output never leaks into a later `receive`.
  """
  @spec flush(port()) :: :ok
  def flush(port) do
    receive do
      {^port, _message} -> flush(port)
    after
      0 -> :ok
    end
  end

  @doc """
  Kills an in-flight run: SIGKILLs the OS process, closes its port, and drains
  any leftover port messages.

  Signals **before** closing the port: closing a `:spawn_executable` port reaps
  the OS process, after which the recorded `os_pid` may be recycled to an
  unrelated process — a `kill` landing then would hit the wrong target. With the
  port still open the pid is guaranteed to still name this run's process.

  Idempotent — safe to call on a run that has already ended. This is the default
  implementation an adapter's `c:Harness.AgentAdapter.terminate/1` delegates to.
  """
  @spec kill(Run.t()) :: :ok
  def kill(%Run{port: port, os_pid: os_pid}) do
    if os_pid, do: sigkill(os_pid)
    close(port)
    flush(port)
  end

  @doc """
  SIGKILLs `os_pid` directly — the raw signal shared by `kill/1` and
  whole-process-tree reap callers.

  Fire-and-forget: a pid that already exited makes `kill(1)` fail quietly.
  """
  @spec sigkill(non_neg_integer()) :: :ok
  def sigkill(os_pid) when is_integer(os_pid) do
    System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  end
end
