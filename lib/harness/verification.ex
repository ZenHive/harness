defmodule Harness.Verification do
  @moduledoc """
  Runs a target project's check stack against a worktree and grades the result.

  When a coding agent finishes, harness must answer "did the job actually
  succeed?" — objectively, never from the agent's self-reported exit code. This
  module is that grader: it runs a configurable list of check commands
  (`Harness.Verification.Check`) against a worktree directory and aggregates
  them into a `Harness.Verification.Verdict`. Any red check makes the whole
  verdict red.

  ## Usage

      {:ok, verdict} = Harness.Verification.run("/path/to/worktree")
      Harness.Verification.Verdict.passed?(verdict)

  `run/2` grades with `elixir_preset/0` — the standard `mix` quality stack —
  unless given a `:checks` option or a `:harness, :verification` config override.

  ## Execution model

  Each check is spawned over an OTP port, bounded by a per-check timeout
  enforced as an absolute deadline: any check still running when the
  deadline passes — idle (a cold `mix dialyzer` PLT build, a block on a TTY) or
  still streaming output — is killed rather than wedging the run. Checks run
  sequentially — the preset checks all touch the target's shared `_build`, so
  concurrent `mix` runs would race the compile lock. A failing check is a red
  result, not a crash; `run/2` returns `{:error, _}` only when verification
  cannot run at all (no checks, or the worktree path is missing).

  ## Configuration

  Under the `:harness, :verification` application key — both keys optional, with
  defaults in code:

    * `:checks` — the check stack, a list of `Harness.Verification.Check`.
      Defaults to `elixir_preset/0`.
    * `:timeout` — the per-check timeout in milliseconds. Defaults to `600000`
      (10 minutes).
  """

  alias Harness.Verification.Check
  alias Harness.Verification.Result
  alias Harness.Verification.Verdict

  @default_timeout 600_000

  @elixir_preset [
    %Check{name: "test", command: "mix", args: ["test.json"]},
    %Check{name: "dialyzer", command: "mix", args: ["dialyzer.json"]},
    %Check{name: "credo", command: "mix", args: ["credo", "--strict"]},
    %Check{name: "doctor", command: "mix", args: ["doctor"]},
    # `--skip` honors the repo's inline `# sobelow_skip` annotations; without it
    # sobelow re-reports every annotated finding and `--exit` reds the check.
    %Check{name: "sobelow", command: "mix", args: ["sobelow", "--exit", "--skip"]}
  ]

  @typedoc "A reason a verification run cannot execute at all."
  @type error :: :no_checks | {:worktree_not_found, String.t()}

  @doc """
  Runs the check stack against the worktree at `worktree_path` and returns a verdict.

  Resolves the check list from the `:checks` option, else the
  `:harness, :verification` config, else `elixir_preset/0`. Each check runs in
  `worktree_path` with a per-check timeout (`:timeout` option, else config, else
  10 minutes). A failing check produces a red `Harness.Verification.Result`, not
  an error — `run/2` returns `{:error, _}` only when verification cannot run at
  all.

  Options:

    * `:checks` — override the check stack with a list of
      `Harness.Verification.Check`.
    * `:timeout` — override the per-check timeout, in milliseconds.

  Returns `{:ok, %Harness.Verification.Verdict{}}`, or `{:error, reason}` —
  `:no_checks` when the stack is empty, `{:worktree_not_found, path}` when
  `worktree_path` is not a directory.
  """
  @spec run(String.t(), keyword()) :: {:ok, Verdict.t()} | {:error, error()}
  def run(worktree_path, opts \\ []) when is_binary(worktree_path) do
    path = Path.expand(worktree_path)
    checks = Keyword.get(opts, :checks) || configured_checks()
    timeout = Keyword.get(opts, :timeout) || configured_timeout()

    with :ok <- validate_checks(checks),
         :ok <- validate_worktree(path) do
      results = Enum.map(checks, &run_check(&1, path, timeout))
      {:ok, build_verdict(results)}
    end
  end

  @doc """
  The default Elixir verification check set: the standard `mix` quality stack.

  Each check is configured with flags that make the tool exit non-zero on
  failure, so the process exit status is a reliable pass/fail signal. The order
  runs `test` first so the later checks reuse the `_build` it produces.
  """
  @spec elixir_preset() :: [Check.t()]
  def elixir_preset, do: @elixir_preset

  @spec configured_checks() :: [Check.t()]
  defp configured_checks do
    :harness
    |> Application.get_env(:verification, [])
    |> Keyword.get(:checks, @elixir_preset)
  end

  @spec configured_timeout() :: timeout()
  defp configured_timeout do
    :harness
    |> Application.get_env(:verification, [])
    |> Keyword.get(:timeout, @default_timeout)
  end

  @spec validate_checks([Check.t()]) :: :ok | {:error, :no_checks}
  defp validate_checks([]), do: {:error, :no_checks}
  defp validate_checks([_ | _]), do: :ok

  @spec validate_worktree(String.t()) :: :ok | {:error, {:worktree_not_found, String.t()}}
  defp validate_worktree(path) do
    if File.dir?(path), do: :ok, else: {:error, {:worktree_not_found, path}}
  end

  @spec build_verdict([Result.t()]) :: Verdict.t()
  defp build_verdict(results) do
    status = if Enum.all?(results, &(&1.status == :pass)), do: :pass, else: :fail
    %Verdict{status: status, results: results}
  end

  # Spawns one check over an OTP port and collects its result. A check whose
  # executable is not on PATH never launches — that is a red result, not a
  # crash, so the verdict still reports every sibling check.
  @spec run_check(Check.t(), String.t(), timeout()) :: Result.t()
  defp run_check(%Check{} = check, worktree_path, timeout) do
    case System.find_executable(check.command) do
      nil ->
        fail_result(check, "could not launch #{inspect(check.command)}: not found on PATH")

      executable ->
        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            :hide,
            :stderr_to_stdout,
            {:args, check.args},
            {:cd, worktree_path}
          ])

        collect(port, check, timeout, deadline(timeout), [])
    end
  end

  # Drains the port until the check exits or its deadline passes. The deadline
  # is absolute: unlike a `receive`-local timeout, a check that keeps emitting
  # output cannot push it back. A passed deadline kills the check and grades it
  # red — a hung check, idle or not, must never wedge the run.
  @spec collect(port(), Check.t(), timeout(), integer() | :infinity, iodata()) :: Result.t()
  defp collect(port, check, timeout, deadline, acc) do
    receive do
      {^port, {:data, data}} ->
        collect(port, check, timeout, deadline, [acc, data])

      {^port, {:exit_status, status}} ->
        %Result{
          name: check.name,
          command: check.command,
          status: if(status == 0, do: :pass, else: :fail),
          kind: :exited,
          exit_status: status,
          output: IO.iodata_to_binary(acc)
        }
    after
      remaining(deadline) ->
        kill_port(port)
        output = IO.iodata_to_binary(acc) <> "\n[harness] check timed out after #{timeout}ms"

        %Result{
          name: check.name,
          command: check.command,
          status: :fail,
          kind: :timed_out,
          exit_status: nil,
          output: output
        }
    end
  end

  # Absolute monotonic-time deadline (ms) for a check, or :infinity when the
  # configured timeout is unbounded.
  @spec deadline(timeout()) :: integer() | :infinity
  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  # Milliseconds left until the deadline, floored at 0 so `receive`'s `after`
  # never sees a negative value; :infinity passes through unchanged.
  @spec remaining(integer() | :infinity) :: timeout()
  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))

  # Best-effort kill of a timed-out check: close the port and SIGKILL the OS
  # process. SIGKILL of the immediate pid can orphan grandchildren — the same
  # limitation as `Harness.AgentAdapter.terminate/1`; the boot-time
  # `Harness.Worktree.Sweeper` is the backstop.
  @spec kill_port(port()) :: :ok
  defp kill_port(port) do
    os_pid = port_os_pid(port)
    close_port(port)
    if os_pid, do: System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    flush_port(port)
  end

  @spec port_os_pid(port()) :: non_neg_integer() | nil
  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      nil -> nil
    end
  end

  @spec close_port(port()) :: :ok
  defp close_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # Drops any port messages already queued before the close, so they never leak
  # into the caller's mailbox.
  @spec flush_port(port()) :: :ok
  defp flush_port(port) do
    receive do
      {^port, _message} -> flush_port(port)
    after
      0 -> :ok
    end
  end

  @spec fail_result(Check.t(), String.t()) :: Result.t()
  defp fail_result(%Check{} = check, message) do
    %Result{
      name: check.name,
      command: check.command,
      status: :fail,
      kind: :not_launched,
      exit_status: nil,
      output: "[harness] " <> message
    }
  end
end
