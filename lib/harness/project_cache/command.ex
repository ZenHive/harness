defmodule Harness.ProjectCache.Command do
  @moduledoc false

  alias Harness.AgentAdapter.OSProcess

  @output_limit 65_536

  @doc false
  @spec run(String.t(), String.t(), map(), reference(), integer(), :output | :digest) ::
          {:ok, String.t()} | {:error, term()}
  def run(command, cwd, env, owner, deadline, capture \\ :output) do
    args = [
      "--wait",
      "sh",
      "-c",
      ~S(printf '__HARNESS_CACHE_PGID__=%s\n' "$$"; exec sh -c "$1"),
      "cache-command",
      command
    ]

    with {:ok, port} <- open("setsid", args, cwd, env) do
      try do
        case started(port, deadline, "") do
          {:ok, group, output} ->
            result =
              collect(port, owner, deadline, output, :crypto.hash_update(:crypto.hash_init(:sha256), output), capture)

            if result in [{:error, :timeout}, {:error, :interrupted}], do: stop_group(port, group)
            result

          {:error, _} = error ->
            error
        end
      after
        OSProcess.close(port)
      end
    end
  end

  @doc false
  @spec locked(String.t(), reference(), integer(), (-> term())) :: term()
  def locked(path, owner, deadline, fun) do
    # The lock process holds an OS advisory lock until stdin closes. The BEAM
    # owns publication; a surviving command after a host crash cannot publish.
    with {:ok, port} <-
           open(
             "flock",
             ["-x", path, "sh", "-c", "printf '__HARNESS_CACHE_LOCKED__\\n'; cat >/dev/null"],
             Path.dirname(path),
             %{}
           ) do
      try do
        with :ok <- await_lock(port, owner, deadline, ""), do: fun.()
      after
        if pid = OSProcess.os_pid(port), do: OSProcess.sigkill(pid)
        OSProcess.close(port)
      end
    end
  end

  @doc false
  @spec alive(reference()) :: :ok | {:error, :interrupted}
  def alive(owner) do
    receive do
      {:DOWN, ^owner, :process, _pid, _reason} -> {:error, :interrupted}
    after
      0 -> :ok
    end
  end

  @doc false
  @spec check(reference(), integer()) :: :ok | {:error, :interrupted | :timeout}
  def check(owner, deadline) do
    with :ok <- alive(owner) do
      if remaining(deadline) == 0, do: {:error, :timeout}, else: :ok
    end
  end

  @spec open(String.t(), [String.t()], String.t(), map()) :: {:ok, port()} | {:error, term()}
  defp open(executable, args, cwd, env) do
    case System.find_executable(executable) do
      nil -> {:error, {:missing_executable, executable}}
      path -> spawn_port(path, args, cwd, env)
    end
  end

  @spec spawn_port(String.t(), [String.t()], String.t(), map()) :: {:ok, port()} | {:error, term()}
  defp spawn_port(path, args, cwd, env) do
    {:ok,
     Port.open({:spawn_executable, path}, [
       :binary,
       :exit_status,
       :stderr_to_stdout,
       args: args,
       cd: cwd,
       env: port_env(env)
     ])}
  rescue
    error in ErlangError -> {:error, {:spawn_failed, error.original}}
  end

  @spec port_env(map()) :: [{charlist(), charlist() | false}]
  defp port_env(snapshot) do
    removed = System.get_env() |> Map.keys() |> Enum.reject(&Map.has_key?(snapshot, &1))

    Enum.map(removed, &{String.to_charlist(&1), false}) ++
      Enum.map(snapshot, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end

  @spec collect(port(), reference(), integer(), binary(), term(), :output | :digest) ::
          {:ok, binary()} | {:error, term()}
  defp collect(port, owner, deadline, output, digest, capture) do
    receive do
      {^port, {:data, chunk}} ->
        collect(port, owner, deadline, tail(output <> chunk), :crypto.hash_update(digest, chunk), capture)

      {^port, {:exit_status, 0}} ->
        {:ok, captured(capture, output, digest)}

      {^port, {:exit_status, status}} ->
        {:error, {:command_exit, status, output}}

      {:DOWN, ^owner, :process, _pid, _reason} ->
        {:error, :interrupted}
    after
      remaining(deadline) -> {:error, :timeout}
    end
  end

  @spec captured(:output | :digest, binary(), term()) :: binary()
  defp captured(:output, output, _digest), do: output
  defp captured(:digest, _output, digest), do: :crypto.hash_final(digest)

  @doc false
  @spec run_all([String.t()], String.t(), map(), reference(), integer(), :output | :digest) ::
          {:ok, [String.t()]} | {:error, term()}
  def run_all(commands, cwd, env, owner, deadline, capture \\ :output) do
    commands
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {command, index}, {:ok, outputs} ->
      case run(command, cwd, env, owner, deadline, capture) do
        {:ok, output} -> {:cont, {:ok, outputs ++ [output]}}
        {:error, reason} -> {:halt, {:error, {:preparation_command, index, reason}}}
      end
    end)
  end

  @spec tail(binary()) :: binary()
  defp tail(output) when byte_size(output) > @output_limit,
    do: binary_part(output, byte_size(output) - @output_limit, @output_limit)

  defp tail(output), do: output

  @spec remaining(integer()) :: non_neg_integer()
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  @spec await_lock(port(), reference(), integer(), binary()) :: :ok | {:error, term()}
  defp await_lock(port, owner, deadline, output) do
    receive do
      {^port, {:data, chunk}} ->
        output = tail(output <> chunk)

        if String.contains?(output, "__HARNESS_CACHE_LOCKED__\n"),
          do: :ok,
          else: await_lock(port, owner, deadline, output)

      {^port, {:exit_status, status}} ->
        {:error, {:lock_exit, status}}

      {:DOWN, ^owner, :process, _pid, _reason} ->
        {:error, :interrupted}
    after
      remaining(deadline) -> {:error, :timeout}
    end
  end

  @spec started(port(), integer(), binary()) :: {:ok, pos_integer(), binary()} | {:error, term()}
  defp started(port, deadline, buffer) do
    case String.split(buffer, "\n", parts: 2) do
      ["__HARNESS_CACHE_PGID__=" <> pid, rest] ->
        case Integer.parse(pid) do
          {group, ""} when group > 0 -> {:ok, group, rest}
          _ -> {:error, {:command_start_protocol, tail(pid)}}
        end

      [_diagnostic, rest] ->
        started(port, deadline, rest)

      [partial] ->
        await_start(port, deadline, partial)
    end
  end

  @spec await_start(port(), integer(), binary()) :: {:ok, pos_integer(), binary()} | {:error, term()}
  defp await_start(port, deadline, buffer) do
    receive do
      {^port, {:data, data}} -> started(port, deadline, tail(buffer <> data))
      {^port, {:exit_status, status}} -> {:error, {:command_start_exit, status}}
    after
      max(remaining(deadline), 1000) -> {:error, :timeout}
    end
  end

  @spec stop_group(port(), pos_integer()) :: :ok
  defp stop_group(port, group) do
    if Port.info(port) do
      System.cmd("kill", ["-KILL", "--", "-#{group}"], stderr_to_stdout: true)
    end

    :ok
  end
end
