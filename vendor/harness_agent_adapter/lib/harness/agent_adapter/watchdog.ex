defmodule Harness.AgentAdapter.Watchdog do
  @moduledoc """
  Deterministic mid-run watchdog for adapter driver halts.

  Owns byte-idle deadlines, total deadlines, progress stalls, and blocked
  command detection. It stays inside the adapter subsystem so the Port driver
  does not depend on the supervised run lifecycle.

  When `new/3` is given no `:progress_timeout` option it falls back to
  `config :harness_agent_adapter, :run, progress_timeout: <ms>` and then to
  `300_000` ms (5 minutes). See `Harness.AgentAdapter.Driver` for the
  full configuration surface.
  """

  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Run

  @default_progress_timeout 300_000

  @type deadline :: integer()
  @type halt_kind :: {:timed_out, :idle | :total} | {:reflex_halted, reason()}
  @type reason :: :progress_stalled | {:blocked_command, String.t()}

  @type t :: %__MODULE__{
          total_deadline: deadline(),
          idle_timeout: non_neg_integer(),
          idle_deadline: deadline(),
          progress_timeout: non_neg_integer() | nil,
          progress_deadline: deadline() | nil,
          worktree_path: String.t(),
          edit_fingerprint: term()
        }

  defstruct [
    :total_deadline,
    :idle_timeout,
    :idle_deadline,
    :progress_timeout,
    :progress_deadline,
    :worktree_path,
    :edit_fingerprint
  ]

  @doc "Builds watchdog state for a freshly spawned adapter run."
  @spec new(Run.t(), Invocation.t(), keyword()) :: t()
  def new(%Run{} = run, %Invocation{} = invocation, opts) do
    now = System.monotonic_time(:millisecond)
    total = Keyword.fetch!(opts, :total_timeout)
    idle = Keyword.fetch!(opts, :idle_timeout)
    progress = Keyword.get(opts, :progress_timeout, configured_progress_timeout())
    worktree_path = Keyword.get(opts, :worktree_path, invocation.cwd)
    started_ms = System.convert_time_unit(run.started_at, :native, :millisecond)

    %__MODULE__{
      total_deadline: started_ms + total,
      idle_timeout: idle,
      idle_deadline: now + idle,
      progress_timeout: progress,
      progress_deadline: maybe_deadline(now, progress),
      worktree_path: worktree_path,
      edit_fingerprint: edit_fingerprint(worktree_path)
    }
  end

  @doc "Returns the receive wait until the next watchdog deadline."
  @spec wait(t()) :: non_neg_integer()
  def wait(%__MODULE__{progress_deadline: nil} = watchdog) do
    min(remaining(watchdog.total_deadline), remaining(watchdog.idle_deadline))
  end

  def wait(%__MODULE__{} = watchdog) do
    watchdog.total_deadline
    |> remaining()
    |> min(remaining(watchdog.idle_deadline))
    |> min(remaining(watchdog.progress_deadline))
  end

  @doc "Checks whether any watchdog deadline has fired."
  @spec expired(t()) :: {:cont, t()} | {:halt, halt_kind(), t()}
  def expired(%__MODULE__{} = watchdog) do
    cond do
      remaining(watchdog.idle_deadline) == 0 ->
        {:halt, {:timed_out, :idle}, watchdog}

      remaining(watchdog.total_deadline) == 0 ->
        {:halt, {:timed_out, :total}, watchdog}

      progress_expired?(watchdog) ->
        expire_progress(watchdog)

      true ->
        {:cont, watchdog}
    end
  end

  @doc "Folds one output chunk through idle, progress, and command guards."
  @spec on_output(t(), iodata()) :: {:cont, t()} | {:halt, halt_kind(), t()}
  def on_output(%__MODULE__{} = watchdog, chunk) do
    now = System.monotonic_time(:millisecond)
    watchdog = %{watchdog | idle_deadline: now + watchdog.idle_timeout}
    binary = IO.iodata_to_binary(chunk)

    case blocked_command_in(binary, watchdog.worktree_path) do
      nil ->
        {:cont, maybe_note_progress(watchdog, binary, now)}

      {:blocked_command, command} = reason ->
        {:halt, {:reflex_halted, reason}, maybe_note_progress(watchdog, command, now)}
    end
  end

  @doc "Classifies one shell command as blocked, or returns nil when allowed."
  @spec blocked_command(String.t(), String.t()) :: {:blocked_command, String.t()} | nil
  def blocked_command(command, worktree_path) when is_binary(command) and is_binary(worktree_path) do
    normalized = normalize_command(command)
    downcased = String.downcase(normalized)

    cond do
      Regex.match?(~r/\bmix\s+deps\.clean\b/, downcased) ->
        {:blocked_command, normalized}

      Regex.match?(~r/\bgit\s+push\b.*\s(--force|-f|--force-with-lease)(\s|$)/, downcased) ->
        {:blocked_command, normalized}

      rm_rf_outside_worktree?(normalized, worktree_path) ->
        {:blocked_command, normalized}

      true ->
        nil
    end
  end

  @spec configured_progress_timeout() :: non_neg_integer()
  defp configured_progress_timeout do
    :harness_agent_adapter
    |> Application.get_env(:run, [])
    |> Keyword.get(:progress_timeout, @default_progress_timeout)
  end

  @spec maybe_deadline(integer(), non_neg_integer() | nil) :: deadline() | nil
  defp maybe_deadline(_now, nil), do: nil
  defp maybe_deadline(now, timeout), do: now + timeout

  @spec remaining(deadline()) :: non_neg_integer()
  defp remaining(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))

  @spec progress_expired?(t()) :: boolean()
  defp progress_expired?(%__MODULE__{progress_deadline: nil}), do: false
  defp progress_expired?(%__MODULE__{progress_deadline: deadline}), do: remaining(deadline) == 0

  @spec expire_progress(t()) :: {:cont, t()} | {:halt, halt_kind(), t()}
  defp expire_progress(%__MODULE__{} = watchdog) do
    now = System.monotonic_time(:millisecond)
    fingerprint = edit_fingerprint(watchdog.worktree_path)

    if fingerprint == watchdog.edit_fingerprint do
      {:halt, {:reflex_halted, :progress_stalled}, watchdog}
    else
      {:cont, reset_progress(%{watchdog | edit_fingerprint: fingerprint}, now)}
    end
  end

  @spec maybe_note_progress(t(), binary(), integer()) :: t()
  defp maybe_note_progress(%__MODULE__{} = watchdog, binary, now) do
    if tool_call?(binary), do: reset_progress(watchdog, now), else: watchdog
  end

  @spec reset_progress(t(), integer()) :: t()
  defp reset_progress(%__MODULE__{progress_timeout: nil} = watchdog, _now), do: watchdog

  defp reset_progress(%__MODULE__{progress_timeout: timeout} = watchdog, now) do
    %{watchdog | progress_deadline: now + timeout}
  end

  @spec blocked_command_in(binary(), String.t()) :: {:blocked_command, String.t()} | nil
  defp blocked_command_in(binary, worktree_path) do
    binary
    |> extract_commands()
    |> Enum.find_value(&blocked_command(&1, worktree_path))
  end

  @spec extract_commands(binary()) :: [String.t()]
  defp extract_commands(binary) do
    binary
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&commands_from_line/1)
  end

  @spec commands_from_line(binary()) :: [String.t()]
  defp commands_from_line(line) do
    if String.contains?(line, [~s("command"), ~s("cmd")]) do
      case Jason.decode(line) do
        {:ok, decoded} -> commands_from_term(decoded)
        {:error, _reason} -> []
      end
    else
      []
    end
  end

  @spec commands_from_term(term()) :: [String.t()]
  defp commands_from_term(%{} = map) do
    direct =
      ["command", "cmd"]
      |> Enum.map(&Map.get(map, &1))
      |> Enum.filter(&is_binary/1)

    nested = map |> Map.values() |> Enum.flat_map(&commands_from_term/1)
    direct ++ nested
  end

  defp commands_from_term(list) when is_list(list), do: Enum.flat_map(list, &commands_from_term/1)
  defp commands_from_term(_other), do: []

  @spec tool_call?(binary()) :: boolean()
  defp tool_call?(binary) do
    String.contains?(binary, ["\"command_execution\"", "\"tool_use\"", "\"tool_call\""])
  end

  @spec normalize_command(String.t()) :: String.t()
  defp normalize_command(command) do
    command
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  @spec rm_rf_outside_worktree?(String.t(), String.t()) :: boolean()
  defp rm_rf_outside_worktree?(command, worktree_path) do
    tokens = shell_tokens(command)
    expanded_worktree = Path.expand(worktree_path)

    tokens
    |> Enum.with_index()
    |> Enum.any?(fn {token, index} ->
      targets = rm_rf_targets(tokens, index + 1)
      Path.basename(token) == "rm" and outside_worktree?(targets, expanded_worktree)
    end)
  end

  @spec rm_rf_targets([String.t()], non_neg_integer()) :: [String.t()]
  defp rm_rf_targets(tokens, start_index) do
    {flags, rest} =
      tokens
      |> Enum.drop(start_index)
      |> Enum.split_while(&String.starts_with?(&1, "-"))

    recursive_force? =
      Enum.any?(flags, fn flag ->
        String.contains?(flag, "r") and String.contains?(flag, "f")
      end)

    if recursive_force? do
      rest
      |> Enum.take_while(&(not shell_separator?(&1)))
      |> Enum.reject(&String.starts_with?(&1, "-"))
    else
      []
    end
  end

  @spec shell_separator?(String.t()) :: boolean()
  defp shell_separator?(token), do: String.contains?(token, ["&", ";", "|", "<", ">"])

  @spec outside_worktree?([String.t()], String.t()) :: boolean()
  defp outside_worktree?([], _expanded_worktree), do: false

  defp outside_worktree?(targets, expanded_worktree) do
    Enum.any?(targets, &(not inside_safe_zone?(&1, expanded_worktree)))
  end

  @spec inside_safe_zone?(String.t(), String.t()) :: boolean()
  defp inside_safe_zone?(target, expanded_worktree) do
    expanded_target = Path.expand(target, expanded_worktree)

    inside_worktree?(expanded_target, expanded_worktree) or under_temp_root?(expanded_target)
  end

  @spec inside_worktree?(String.t(), String.t()) :: boolean()
  defp inside_worktree?(expanded_target, expanded_worktree) do
    expanded_target == expanded_worktree or String.starts_with?(expanded_target, expanded_worktree <> "/")
  end

  @spec under_temp_root?(String.t()) :: boolean()
  defp under_temp_root?(expanded_target) do
    Enum.any?(temp_roots(), &String.starts_with?(expanded_target, &1 <> "/"))
  end

  @spec temp_roots() :: [String.t()]
  defp temp_roots do
    ["/tmp", System.tmp_dir!()] |> Enum.map(&Path.expand/1) |> Enum.uniq()
  end

  @spec shell_tokens(String.t()) :: [String.t()]
  defp shell_tokens(command) do
    ~r/'[^']*'|"[^"]*"|\S+/
    |> Regex.scan(command)
    |> Enum.map(fn [token] -> token |> String.trim("'") |> String.trim("\"") end)
  end

  @spec edit_fingerprint(String.t()) :: term()
  defp edit_fingerprint(path) do
    path
    |> file_fingerprints()
    |> :erlang.phash2()
  end

  @spec file_fingerprints(String.t()) :: [term()]
  defp file_fingerprints(path) do
    cond do
      not File.exists?(path) ->
        []

      File.dir?(path) ->
        path
        |> File.ls!()
        |> Enum.reject(&(&1 == ".git"))
        |> Enum.sort()
        |> Enum.flat_map(&file_fingerprints(Path.join(path, &1)))

      true ->
        case File.stat(path) do
          {:ok, stat} -> [{path, stat.size, stat.mtime}]
          {:error, _reason} -> []
        end
    end
  end
end
