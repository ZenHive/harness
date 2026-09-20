defmodule Harness.Run.TestDbIsolation do
  @moduledoc """
  Mechanical per-run test database partitioning for agent-gate runs.

  Harness sets the environment variable that Phoenix/Ecto projects already
  conventionally read from `config/test.exs`. An explicit template recipe also
  provisions the partition. The reviewer runs migrations/checks and remains the gate.
  """

  alias Harness.Project
  alias Harness.Run.TestDbPartition
  alias Harness.Run.TestDbTemplate

  require Logger

  @default_env "MIX_TEST_PARTITION"
  @suffix_prefix "_h_"
  @template_path Path.join(__DIR__, "test_db_template.ex")
  @partition_path Path.join(__DIR__, "test_db_partition.ex")
  @external_resource @template_path
  @external_resource @partition_path
  @template_source File.read!(@template_path)
  @partition_source File.read!(@partition_path)

  @doc false
  @spec env(Project.t(), String.t()) :: %{optional(String.t()) => String.t() | false}
  def env(%Project{} = project, run_id) when is_binary(run_id) do
    case env_name(project) do
      {:ok, name} -> %{name => suffix(project, run_id)}
      :disabled -> %{@default_env => false}
    end
  end

  @doc "Provisions an explicitly configured template before agent dispatch."
  @spec prepare(Project.t(), String.t(), String.t(), map()) :: :ok | {:error, term()}
  def prepare(project, worktree_path, run_id, env \\ %{})
  def prepare(%Project{test_db_template: nil}, _path, _run_id, _env), do: :ok

  def prepare(%Project{} = project, path, run_id, env) do
    run_template(project, path, run_id, :prepare, env)
  end

  @doc false
  @spec teardown(Project.t(), String.t() | nil, String.t(), map()) :: :ok
  def teardown(project, worktree_path, run_id, env \\ %{})

  def teardown(%Project{test_db_template: recipe} = project, path, run_id, env)
      when not is_nil(recipe) and is_binary(path) do
    case run_template(project, path, run_id, :drop, env) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("harness run: test DB template cleanup failed: #{inspect(reason)}")
        :ok
    end
  end

  def teardown(%Project{} = project, worktree_path, run_id, env) when is_binary(worktree_path) and is_binary(run_id) do
    teardown_partition(project, worktree_path, partition_suffix(run_id), env)
  end

  def teardown(%Project{}, _worktree_path, _run_id, _env), do: :ok

  @doc """
  Best-effort drop of the test database identified by an explicit partition.

  Isolation opt-out is a no-op so a shared test database is never dropped.
  The drop uses the worktree's resolved Mix.Ecto database name, refuses names
  that do not end with `partition`, and never forces a drop or terminates
  sessions. Failures are logged with evidence and do not raise.
  """
  @spec teardown_partition(Project.t(), String.t() | nil, String.t(), map()) :: :ok
  def teardown_partition(project, worktree_path, partition, extra_env \\ %{})

  def teardown_partition(%Project{} = project, path, partition, extra_env)
      when is_binary(path) and is_binary(partition) and is_map(extra_env) do
    with {:ok, name} <- env_name(project),
         true <- honors_env?(path, name),
         :ok <- TestDbPartition.validate_partition(partition) do
      path
      |> run_partition_drop(cmd_env(extra_env, name, partition), partition)
      |> log_drop_result()
    else
      :disabled ->
        :ok

      false ->
        :ok

      {:error, reason} ->
        Logger.warning("harness: test DB teardown skipped: #{inspect(reason)}")
        :ok
    end
  end

  def teardown_partition(%Project{}, _worktree_path, _partition, _env), do: :ok

  @spec suffix(Project.t(), String.t()) :: String.t()
  defp suffix(%Project{test_db_template: nil}, run_id), do: partition_suffix(run_id)
  defp suffix(%Project{}, run_id), do: TestDbTemplate.partition(run_id)

  @spec run_template(Project.t(), String.t(), String.t(), atom(), map()) :: :ok | {:error, term()}
  defp run_template(project, path, run_id, action, extra_env) do
    with {:ok, recipe} <- TestDbTemplate.normalize(project.test_db_template),
         {:ok, _name} <- env_name(project) do
      code =
        @template_source <>
          "\nHarness.Run.TestDbTemplate.run!(#{inspect(recipe)}, #{inspect(run_id)}, #{inspect(action)})"

      env =
        extra_env
        |> Map.merge(env(project, run_id))
        |> Map.put("MIX_ENV", "test")
        |> Enum.map(fn
          {key, false} -> {key, nil}
          pair -> pair
        end)

      case System.cmd("mix", ["run", "--no-start", "-e", code], cd: path, env: env, stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, status} -> {:error, {:test_db_template, status, String.trim(output)}}
      end
    else
      :disabled -> {:error, {:test_db_template, "template provisioning requires enabled test database isolation"}}
      {:error, reason} -> {:error, {:test_db_template, reason}}
    end
  rescue
    error in ErlangError -> {:error, {:test_db_template, error.original}}
  end

  @doc false
  @spec env_name(Project.t()) :: {:ok, String.t()} | :disabled
  def env_name(%Project{test_db_isolation_env: nil}), do: {:ok, @default_env}
  def env_name(%Project{test_db_isolation_env: false}), do: :disabled
  def env_name(%Project{test_db_isolation_env: :none}), do: :disabled

  def env_name(%Project{test_db_isolation_env: name}) when is_binary(name) do
    case String.trim(name) do
      "" -> :disabled
      trimmed -> env_name_from_string(trimmed)
    end
  end

  @spec env_name_from_string(String.t()) :: {:ok, String.t()} | :disabled
  defp env_name_from_string("none"), do: :disabled
  defp env_name_from_string(name), do: {:ok, name}

  @spec partition_suffix(String.t()) :: String.t()
  defp partition_suffix(run_id) do
    run_id
    |> String.split("-", trim: true)
    |> List.last()
    |> safe_suffix()
  end

  @spec safe_suffix(String.t() | nil) :: String.t()
  defp safe_suffix(nil), do: @suffix_prefix <> "run"

  defp safe_suffix(value) do
    suffix =
      value
      |> String.replace(~r/[^A-Za-z0-9_]/, "_")
      |> String.trim("_")

    @suffix_prefix <> if(suffix == "", do: "run", else: suffix)
  end

  @spec honors_env?(String.t(), String.t()) :: boolean()
  defp honors_env?(worktree_path, env_name) do
    test_config = Path.join([worktree_path, "config", "test.exs"])

    File.regular?(Path.join(worktree_path, "mix.exs")) and config_mentions_env?(test_config, env_name)
  end

  @spec config_mentions_env?(String.t(), String.t()) :: boolean()
  # sobelow_skip ["Traversal.FileModule"] — worktree_path is a harness-managed checkout.
  defp config_mentions_env?(test_config, env_name) do
    case File.read(test_config) do
      {:ok, config} -> String.contains?(config, env_name)
      {:error, _reason} -> false
    end
  end

  @spec cmd_env(map(), String.t(), String.t()) :: [{String.t(), String.t() | nil}]
  defp cmd_env(extra_env, name, partition) do
    extra_env
    |> Map.merge(%{name => partition, "MIX_ENV" => "test"})
    |> Enum.map(fn
      {key, false} -> {key, nil}
      pair -> pair
    end)
  end

  @spec run_partition_drop(String.t(), [{String.t(), String.t() | nil}], String.t()) ::
          {String.t(), non_neg_integer()} | {:error, term()}
  defp run_partition_drop(path, env, partition) do
    code = @partition_source <> "\nHarness.Run.TestDbPartition.run!(#{inspect(partition)})"
    System.cmd("mix", ["run", "--no-start", "-e", code], cd: path, env: env, stderr_to_stdout: true)
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @spec log_drop_result({String.t(), non_neg_integer()} | {:error, term()}) :: :ok
  defp log_drop_result({_output, 0}), do: :ok

  defp log_drop_result({output, status}) when is_integer(status) do
    trimmed = String.trim(output)
    Logger.warning("harness: test DB teardown #{drop_log_label(trimmed)} #{status}: #{trimmed}")
    :ok
  end

  defp log_drop_result({:error, reason}) do
    Logger.warning("harness: test DB teardown failed: #{inspect(reason)}")
    :ok
  end

  @spec drop_log_label(String.t()) :: String.t()
  defp drop_log_label(output) do
    cond do
      String.contains?(output, "active sessions") -> "skipped (active sessions) exit"
      String.contains?(output, "unpartitioned") -> "skipped (unpartitioned) exit"
      true -> "exited"
    end
  end
end
