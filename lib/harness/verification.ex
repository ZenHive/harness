defmodule Harness.Verification do
  @moduledoc """
  Runs a target project's check stack against a worktree and grades the result.

  When a coding agent finishes, harness must answer "did the job actually
  succeed?" — objectively, never from the agent's self-reported exit code. This
  module is that grader: it runs a configurable list of check commands
  (`Harness.Verification.Check`) against a worktree directory and aggregates
  them into a `Harness.Verification.Verdict`. Any red check makes the whole
  verdict red.

  The same module owns the **worktree-provisioning pass**: `prepare/2` runs each
  stack's `setup` commands (deps fetch/compile) against a freshly carved worktree
  *before* the agent spawns, so an agent never starts in a cold working
  directory. `run/2` later re-runs the same setup as a fast no-op.

  ## Usage

      {:ok, verdict} = Harness.Verification.run("/path/to/worktree")
      Harness.Verification.Verdict.passed?(verdict)

  `run/2` grades with `elixir_preset/0` — the standard `mix` quality stack —
  unless given a `:check_stacks` option (a list of `Harness.CheckStack`s), a
  singular `:check_stack`, a raw `:checks` list, or a `:harness, :verification`
  config override.

  ## Multi-stack, multi-directory projects

  A project can carry **more than one** check stack — one per language or
  component in a monorepo (a Rust crate in `rust/`, a Phoenix app in
  `elixir/`). A git worktree is always repo-root-granular, so each stack
  declares a `workdir` (relative to the worktree root) and its checks run with
  that subdirectory as their cwd. Every stack's results are flattened into one
  `Harness.Verification.Verdict`, green iff every check across every stack
  passed. A single-language project is just a one-element list with
  `workdir: ""` (the repo root) — identical to the pre-multi-stack behavior.

  ## Execution model

  Each check is spawned over an OTP port, bounded by a per-check timeout
  enforced as an absolute deadline: any check still running when the
  deadline passes — idle (a cold `mix dialyzer` PLT build, a block on a TTY) or
  still streaming output — is killed rather than wedging the run. Checks run
  sequentially — the preset checks all touch the target's shared `_build`, so
  concurrent `mix` runs would race the compile lock. A failing check is a red
  result, not a crash; `run/2` returns `{:error, _}` only when verification
  cannot run at all (no checks, the worktree path is missing, or a stack's
  `workdir` does not exist).

  ## Configuration

  Under the `:harness, :verification` application key — both keys optional, with
  defaults in code:

    * `:checks` — the check stack, a list of `Harness.Verification.Check`.
      Defaults to `elixir_preset/0`.
    * `:timeout` — the per-check timeout in milliseconds. Defaults to `600000`
      (10 minutes).
  """

  alias Harness.CheckStack
  alias Harness.CheckStack.Preset.Elixir, as: ElixirPreset
  alias Harness.Git
  alias Harness.Verification.Check
  alias Harness.Verification.Result
  alias Harness.Verification.Verdict

  @default_timeout 600_000
  @timeout_output_drain_ms 100
  @test_database_prefix "harness_test"
  @baseline_cache_namespace {__MODULE__, :baseline_cache}

  @typedoc "A reason a verification run cannot execute at all."
  @type error ::
          :no_checks
          | {:worktree_not_found, String.t()}
          | {:workdir_not_found, String.t()}
          | {:setup_failed, setup_failure()}

  @typedoc "A stack's setup/bootstrap step failed — an environment error, not a red verdict."
  @type setup_failure :: %{
          required(:stack) => atom(),
          required(:workdir) => String.t(),
          required(:result) => Result.t()
        }

  @doc """
  Runs the check stack against the worktree at `worktree_path` and returns a verdict.

  Resolves the stacks from the `:check_stacks` option (else `:check_stack`,
  `:checks`, config, or `elixir_preset/0`). Each stack's checks run with its
  `workdir` (relative to `worktree_path`) as their cwd, under a per-check
  timeout (`:timeout` option, else the stack's `timeout_per_check`, else
  config, else 10 minutes). All stacks' results are flattened into one verdict.
  A failing check produces a red `Harness.Verification.Result`, not an error —
  `run/2` returns `{:error, _}` only when verification cannot run at all.

  Options:

    * `:check_stacks` — a list of `Harness.CheckStack`s, each run in its own
      `workdir`. The canonical multi-language form. Wins over the singular
      options below.
    * `:check_stack` — a single `Harness.CheckStack` (treated as a one-element
      `:check_stacks` list). Its `checks` and (when set) `timeout_per_check`
      drive the run.
    * `:checks` — override the check stack with a raw list of
      `Harness.Verification.Check`, run at the repo root. Back-compat path; new
      callers should prefer `:check_stacks`.
    * `:timeout` — override the per-check timeout, in milliseconds, or
      `:infinity` for an unbounded check. Applies to every stack.
    * `:base_ref` — the dispatch-base commit SHA the worktree branch was
      forked from. When set, diff-aware post-processors (see
      `t:Harness.Verification.Check.post_process/0`) re-grade their checks
      against the baseline — e.g. the credo TagTODO filter drops findings on
      pre-existing TODOs. The post-process context stays at the worktree root
      (the diff is whole-repo) even when a stack's checks run in a subdir.
      `nil` (the default) leaves every check's exit status as the sole grader.

  Returns `{:ok, %Harness.Verification.Verdict{}}`, or `{:error, reason}` —
  `:no_checks` when no stack has checks, `{:worktree_not_found, path}` when
  `worktree_path` is not a directory, `{:workdir_not_found, dir}` when a
  stack's resolved `workdir` does not exist, `{:setup_failed, details}` when a
  stack's bootstrap step fails (environment error — not a red verdict).
  """
  @spec run(String.t(), keyword()) :: {:ok, Verdict.t()} | {:error, error()}
  def run(worktree_path, opts \\ []) when is_binary(worktree_path) do
    path = Path.expand(worktree_path)
    stacks = resolve_stacks(opts)
    timeout_override = Keyword.get(opts, :timeout)
    post_process_opts = post_process_opts(path, opts)

    with :ok <- validate_stacks(stacks),
         :ok <- validate_worktree(path),
         {:ok, results} <- run_stacks(stacks, path, timeout_override, post_process_opts) do
      results = maybe_mark_pre_existing(results, stacks, path, timeout_override, post_process_opts)
      {:ok, build_verdict(results)}
    end
  end

  @doc """
  Runs every stack's setup/bootstrap commands against the worktree at
  `worktree_path`, without grading any checks.

  This is the worktree-provisioning pass: `Harness.Run` calls it after carving
  a run's worktree and *before* spawning the agent, so the agent starts in a
  warm working directory (deps fetched and compiled) instead of burning its
  idle/progress budget on a silent cold build. `run/2` later re-runs the same
  setup ahead of the checks, where it is a fast no-op against the warmed
  `_build`.

  Accepts the same options as `run/2` (`:check_stacks` / `:check_stack` /
  `:checks` / `:timeout`); stacks whose `setup` is empty are skipped. Returns
  `:ok`, or `{:error, reason}` with `run/2`'s error vocabulary — a setup
  failure is an environment error (`{:setup_failed, details}`), never a red
  verdict.
  """
  @spec prepare(String.t(), keyword()) :: :ok | {:error, error()}
  def prepare(worktree_path, opts \\ []) when is_binary(worktree_path) do
    path = Path.expand(worktree_path)
    stacks = resolve_stacks(opts)
    timeout_override = Keyword.get(opts, :timeout)
    post_process_opts = post_process_opts(path, opts)

    with :ok <- validate_worktree(path) do
      prepare_stacks(stacks, path, timeout_override, post_process_opts)
    end
  end

  # Runs each stack's setup in its own `workdir`, halting on the first
  # environment error. Mirrors `run_stacks/4` minus the grading checks.
  @spec prepare_stacks([CheckStack.t()], String.t(), timeout() | nil, keyword()) ::
          :ok | {:error, {:workdir_not_found, String.t()} | {:setup_failed, setup_failure()}}
  defp prepare_stacks(stacks, path, timeout_override, post_process_opts) do
    Enum.reduce_while(stacks, :ok, fn stack, :ok ->
      case prepare_stack(stack, path, timeout_override, post_process_opts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec prepare_stack(CheckStack.t(), String.t(), timeout() | nil, keyword()) ::
          :ok | {:error, {:workdir_not_found, String.t()} | {:setup_failed, setup_failure()}}
  defp prepare_stack(%CheckStack{setup: []}, _path, _timeout_override, _post_process_opts), do: :ok

  defp prepare_stack(%CheckStack{} = stack, path, timeout_override, post_process_opts) do
    check_dir = stack_dir(path, stack.workdir)
    timeout = timeout_override || stack.timeout_per_check || configured_timeout()

    if File.dir?(check_dir) do
      run_setup(stack, check_dir, timeout, post_process_opts, dynamic_env(path, stack))
    else
      {:error, {:workdir_not_found, check_dir}}
    end
  end

  @doc """
  The default Elixir verification check set: the standard `mix` quality stack.

  Each check is configured with flags that make the tool exit non-zero on
  failure, so the process exit status is a reliable pass/fail signal. The order
  runs `test` first so the later checks reuse the `_build` it produces.

  Delegates to `Harness.CheckStack.Preset.Elixir.preset/0` — that module owns
  the canonical Elixir check list; this function preserves the historical
  call shape `[Check.t()]`.
  """
  @spec elixir_preset() :: [Check.t()]
  def elixir_preset, do: ElixirPreset.preset().checks

  # Resolves the list of `%CheckStack{}`s to run from `opts`. `:check_stacks`
  # (a list) wins; else a singular `:check_stack` becomes a one-element list;
  # else a raw `:checks` list (or the configured/preset fallback) is wrapped in
  # a synthetic root-level stack. All fallbacks run at the repo root
  # (`workdir: ""`).
  @spec resolve_stacks(keyword()) :: [CheckStack.t()]
  defp resolve_stacks(opts) do
    cond do
      is_list(Keyword.get(opts, :check_stacks)) ->
        Keyword.fetch!(opts, :check_stacks)

      match?(%CheckStack{}, Keyword.get(opts, :check_stack)) ->
        [Keyword.fetch!(opts, :check_stack)]

      true ->
        [%CheckStack{name: :default, checks: Keyword.get(opts, :checks) || configured_checks()}]
    end
  end

  # Runs every stack in its own `workdir` (relative to the worktree root) and
  # concatenates the results stack-by-stack. Bails with `{:workdir_not_found,
  # dir}` the first time a stack's resolved directory is missing — a clear
  # harness error instead of the cryptic per-tool "could not find <manifest>"
  # a misconfigured workdir would otherwise produce. Setup/bootstrap runs
  # before each stack's checks; a setup failure halts with `{:setup_failed, _}`.
  @spec run_stacks([CheckStack.t()], String.t(), timeout() | nil, keyword()) ::
          {:ok, [Result.t()]}
          | {:error, {:workdir_not_found, String.t()} | {:setup_failed, setup_failure()}}
  defp run_stacks(stacks, path, timeout_override, post_process_opts) do
    Enum.reduce_while(stacks, {:ok, []}, fn stack, {:ok, acc} ->
      case run_stack(stack, path, timeout_override, post_process_opts) do
        {:ok, results} -> {:cont, {:ok, acc ++ results}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec run_stack(CheckStack.t(), String.t(), timeout() | nil, keyword()) ::
          {:ok, [Result.t()]}
          | {:error, {:workdir_not_found, String.t()} | {:setup_failed, setup_failure()}}
  defp run_stack(stack, path, timeout_override, post_process_opts) do
    check_dir = stack_dir(path, stack.workdir)

    if File.dir?(check_dir) do
      timeout = timeout_override || stack.timeout_per_check || configured_timeout()

      run_env = dynamic_env(path, stack)

      with :ok <- run_setup(stack, check_dir, timeout, post_process_opts, run_env) do
        {:ok, Enum.map(stack.checks, &run_check(&1, check_dir, timeout, post_process_opts, run_env))}
      end
    else
      {:error, {:workdir_not_found, check_dir}}
    end
  end

  # Runs a stack's non-grading bootstrap commands before its checks. Empty setup
  # is a no-op. The first failing setup step halts with `{:setup_failed, _}` —
  # an environment error distinct from a red verdict.
  @spec run_setup(CheckStack.t(), String.t(), timeout(), keyword(), map()) ::
          :ok | {:error, {:setup_failed, setup_failure()}}
  defp run_setup(%CheckStack{setup: []}, _check_dir, _timeout, _post_process_opts, _run_env), do: :ok

  defp run_setup(%CheckStack{} = stack, check_dir, timeout, post_process_opts, run_env) do
    stack.setup
    |> Enum.reduce_while(:ok, fn check, :ok ->
      case run_check(check, check_dir, timeout, post_process_opts, run_env) do
        %Result{status: :pass} ->
          {:cont, :ok}

        %Result{} = result ->
          {:halt, {:error, {:setup_failed, %{stack: stack.name, workdir: check_dir, result: result}}}}
      end
    end)
    |> case do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # The absolute cwd a stack's checks run in: the worktree root, offset by the
  # stack's `workdir`. `nil`/`""` means the repo root itself.
  @spec stack_dir(String.t(), String.t() | nil) :: String.t()
  defp stack_dir(path, workdir) when workdir in [nil, ""], do: path
  defp stack_dir(path, workdir), do: Path.join(path, workdir)

  @spec dynamic_env(String.t(), CheckStack.t()) :: %{atom() => String.t()}
  defp dynamic_env(path, %CheckStack{} = stack) do
    %{test_database: test_database_name(path, stack)}
  end

  @spec test_database_name(String.t(), CheckStack.t()) :: String.t()
  defp test_database_name(path, %CheckStack{name: name}) do
    slug =
      [Path.basename(path), to_string(name), :erlang.phash2(path)]
      |> Enum.join("_")
      |> String.replace(~r/[^A-Za-z0-9_]/, "_")
      |> String.trim("_")

    "#{@test_database_prefix}_#{slug}"
  end

  @spec configured_checks() :: [Check.t()]
  defp configured_checks do
    :harness
    |> Application.get_env(:verification, [])
    |> Keyword.get(:checks, elixir_preset())
  end

  @spec configured_timeout() :: timeout()
  defp configured_timeout do
    :harness
    |> Application.get_env(:verification, [])
    |> Keyword.get(:timeout, @default_timeout)
  end

  # A run is executable iff at least one stack carries at least one check;
  # otherwise there is nothing to grade.
  @spec validate_stacks([CheckStack.t()]) :: :ok | {:error, :no_checks}
  defp validate_stacks(stacks) do
    if Enum.any?(stacks, &(&1.checks != [])), do: :ok, else: {:error, :no_checks}
  end

  @spec validate_worktree(String.t()) :: :ok | {:error, {:worktree_not_found, String.t()}}
  defp validate_worktree(path) do
    if File.dir?(path), do: :ok, else: {:error, {:worktree_not_found, path}}
  end

  @spec build_verdict([Result.t()]) :: Verdict.t()
  defp build_verdict(results) do
    status =
      cond do
        Enum.any?(results, &(&1.status == :fail)) -> :fail
        Enum.any?(results, &(&1.status == :pre_existing)) -> :base_red
        true -> :pass
      end

    %Verdict{status: status, results: results}
  end

  @spec maybe_mark_pre_existing([Result.t()], [CheckStack.t()], String.t(), timeout() | nil, keyword()) ::
          [Result.t()]
  defp maybe_mark_pre_existing(results, stacks, path, timeout_override, post_process_opts) do
    base_ref = Keyword.get(post_process_opts, :base_ref)

    if red_results?(results) and is_binary(base_ref) do
      case baseline_results(stacks, path, timeout_override, base_ref) do
        {:ok, baseline_results} -> mark_pre_existing(results, baseline_results)
        {:error, _reason} -> results
      end
    else
      results
    end
  end

  @spec red_results?([Result.t()]) :: boolean()
  defp red_results?(results), do: Enum.any?(results, &(&1.status == :fail))

  @spec baseline_results([CheckStack.t()], String.t(), timeout() | nil, String.t()) ::
          {:ok, [Result.t()]} | {:error, term()}
  defp baseline_results(stacks, path, timeout_override, base_ref) do
    with {:ok, key} <- baseline_cache_key(stacks, path, timeout_override, base_ref) do
      case baseline_cache_get(key) do
        {:ok, cached} ->
          cached

        :error ->
          result = run_baseline_stacks(stacks, path, timeout_override, base_ref)
          baseline_cache_put(key, result)
          result
      end
    end
  end

  @spec baseline_cache_key([CheckStack.t()], String.t(), timeout() | nil, String.t()) ::
          {:ok, term()} | {:error, term()}
  defp baseline_cache_key(stacks, path, timeout_override, base_ref) do
    with {:ok, git_common_dir} <- Git.run(["rev-parse", "--git-common-dir"], path) do
      {:ok,
       {
         Path.expand(String.trim(git_common_dir), path),
         base_ref,
         :erlang.phash2({stacks, timeout_override})
       }}
    end
  end

  @spec baseline_cache_get(term()) :: {:ok, {:ok, [Result.t()]} | {:error, term()}} | :error
  defp baseline_cache_get(key) do
    case :persistent_term.get({@baseline_cache_namespace, key}, :missing) do
      :missing -> :error
      cached -> {:ok, cached}
    end
  end

  @spec baseline_cache_put(term(), {:ok, [Result.t()]} | {:error, term()}) :: :ok
  defp baseline_cache_put(key, result) do
    :persistent_term.put({@baseline_cache_namespace, key}, result)
  end

  @spec run_baseline_stacks([CheckStack.t()], String.t(), timeout() | nil, String.t()) ::
          {:ok, [Result.t()]} | {:error, term()}
  defp run_baseline_stacks(stacks, path, timeout_override, base_ref) do
    baseline_path = baseline_worktree_path(path)

    with {:ok, _output} <- Git.run(["worktree", "add", "--detach", baseline_path, base_ref], path) do
      try do
        run_stacks(stacks, baseline_path, timeout_override, worktree_path: baseline_path)
      after
        _ = Git.run(["worktree", "remove", "--force", baseline_path], path)
      end
    end
  end

  @spec baseline_worktree_path(String.t()) :: String.t()
  defp baseline_worktree_path(path) do
    suffix = "#{Path.basename(path)}-base-#{System.unique_integer([:positive])}"
    Path.join(System.tmp_dir!(), suffix)
  end

  @spec mark_pre_existing([Result.t()], [Result.t()]) :: [Result.t()]
  defp mark_pre_existing(results, baseline_results) when length(results) == length(baseline_results) do
    results
    |> Enum.zip(baseline_results)
    |> Enum.map(fn
      {%Result{status: :fail} = result, %Result{status: :fail}} -> pre_existing_result(result)
      {result, _baseline_result} -> result
    end)
  end

  defp mark_pre_existing(results, _baseline_results), do: results

  @spec pre_existing_result(Result.t()) :: Result.t()
  defp pre_existing_result(%Result{} = result) do
    %{
      result
      | status: :pre_existing,
        output:
          result.output <>
            "\n[harness] check also failed on the dispatch base; marked pre-existing instead of agent-caused"
    }
  end

  # Spawns one check over an OTP port and collects its result. A check whose
  # executable is not on PATH never launches — that is a red result, not a
  # crash, so the verdict still reports every sibling check. Any
  # `post_process` hook on the check runs after the port exits (or times out),
  # so it sees the same `Result` shape the verdict will carry.
  @spec run_check(Check.t(), String.t(), timeout(), keyword(), map()) :: Result.t()
  defp run_check(%Check{} = check, worktree_path, timeout, post_process_opts, run_env) do
    raw_result = collect_check(check, worktree_path, timeout, run_env)
    Check.apply_post_process(check, raw_result, post_process_opts)
  end

  @spec collect_check(Check.t(), String.t(), timeout(), map()) :: Result.t()
  defp collect_check(%Check{} = check, worktree_path, timeout, run_env) do
    case System.find_executable(check.command) do
      nil ->
        fail_result(check, "could not launch #{inspect(check.command)}: not found on PATH")

      executable ->
        port =
          Port.open(
            {:spawn_executable, executable},
            port_options(check, worktree_path, run_env)
          )

        collect(port, check, timeout, deadline(timeout), [])
    end
  end

  @spec port_options(Check.t(), String.t(), map()) :: [term()]
  defp port_options(%Check{} = check, worktree_path, run_env) do
    maybe_put_env(
      [:binary, :exit_status, :hide, :stderr_to_stdout, {:args, check.args}, {:cd, worktree_path}],
      check.env,
      run_env
    )
  end

  @spec maybe_put_env([term()], %{String.t() => Check.env_value()} | nil, map()) :: [term()]
  defp maybe_put_env(options, env, _run_env) when env in [nil, %{}], do: options

  defp maybe_put_env(options, env, run_env) when is_map(env) do
    [{:env, Enum.map(env, fn {key, value} -> {String.to_charlist(key), env_port_value(value, run_env)} end)} | options]
  end

  @spec resolve_env_value(Check.env_value(), map()) :: String.t() | false
  defp resolve_env_value({:harness, key}, run_env), do: Map.fetch!(run_env, key)
  defp resolve_env_value(value, _run_env) when is_binary(value) or value == false, do: value

  @spec env_port_value(Check.env_value(), map()) :: charlist() | false
  defp env_port_value(value, run_env) do
    case resolve_env_value(value, run_env) do
      false -> false
      resolved -> String.to_charlist(resolved)
    end
  end

  # The opts each `post_process` hook receives: the absolute worktree path
  # plus any caller-supplied diff-aware context (currently `:base_ref`).
  @spec post_process_opts(String.t(), keyword()) :: keyword()
  defp post_process_opts(worktree_path, opts) do
    maybe_put([worktree_path: worktree_path], :base_ref, Keyword.get(opts, :base_ref))
  end

  @spec maybe_put(keyword(), atom(), term()) :: keyword()
  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # Drains the port until the check exits or its deadline passes. The deadline
  # is absolute: unlike a `receive`-local timeout, a check that keeps emitting
  # output cannot push it back. The pre-`receive` guard closes the starvation
  # gap — a check flooding stdout fast enough to keep the mailbox non-empty
  # would otherwise let `receive` always match a `{:data, _}` and never reach
  # the `after` clause. A passed deadline kills the check and grades it red — a
  # hung check, idle or flooding, must never wedge the run.
  @spec collect(port(), Check.t(), timeout(), integer() | :infinity, iodata()) :: Result.t()
  defp collect(port, check, timeout, deadline, acc) do
    if deadline_passed?(deadline) do
      timed_out_result(port, check, timeout, acc)
    else
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
          timed_out_result(port, check, timeout, acc)
      end
    end
  end

  # Kills a check that hit its deadline and grades it red.
  @spec timed_out_result(port(), Check.t(), timeout(), iodata()) :: Result.t()
  defp timed_out_result(port, check, timeout, acc) do
    acc = drain_port_output(port, acc, 0)
    kill_port(port)
    acc = drain_port_output(port, acc, @timeout_output_drain_ms)
    close_port(port)
    acc = drain_port_output(port, acc, 0)
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

  # Whether an absolute deadline has already elapsed; `:infinity` never has.
  @spec deadline_passed?(integer() | :infinity) :: boolean()
  defp deadline_passed?(:infinity), do: false
  defp deadline_passed?(deadline), do: System.monotonic_time(:millisecond) >= deadline

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

  # Best-effort kill of a timed-out check. SIGKILL of the immediate pid can
  # orphan grandchildren — the same limitation as `Harness.AgentAdapter.terminate/1`;
  # the boot-time `Harness.Worktree.Sweeper` is the backstop.
  @spec kill_port(port()) :: :ok
  defp kill_port(port) do
    os_pid = port_os_pid(port)

    if os_pid do
      System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end

    :ok
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

  @spec drain_port_output(port(), iodata(), non_neg_integer()) :: iodata()
  defp drain_port_output(port, acc, wait_ms) do
    receive do
      {^port, {:data, data}} -> drain_port_output(port, [acc, data], wait_ms)
      {^port, _message} -> drain_port_output(port, acc, wait_ms)
    after
      wait_ms -> acc
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
