defmodule Harness.Run.TestDbIsolation do
  @moduledoc """
  Mechanical per-run test database partitioning for agent-gate runs.

  Harness sets the environment variable that Phoenix/Ecto projects already
  conventionally read from `config/test.exs`. An explicit template recipe also
  provisions the partition. The reviewer runs migrations/checks and remains the gate.
  """

  alias Harness.Project
  alias Harness.Run.TestDbTemplate

  require Logger

  @default_env "MIX_TEST_PARTITION"
  @suffix_prefix "_h_"
  @drop_args ["ecto.drop", "--quiet"]
  @external_resource Path.join(__DIR__, "test_db_template.ex")
  @template_source File.read!(@external_resource)

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

  def teardown(%Project{} = project, worktree_path, run_id, _env) when is_binary(worktree_path) and is_binary(run_id) do
    with {:ok, name} <- env_name(project),
         true <- honors_env?(worktree_path, name),
         env = [{name, partition_suffix(run_id)}, {"MIX_ENV", "test"}],
         {_output, 0} <- run_drop(worktree_path, env) do
      :ok
    else
      :disabled ->
        :ok

      false ->
        :ok

      {:error, reason} ->
        Logger.warning("harness run: test DB teardown failed: #{inspect(reason)}")
        :ok

      {output, status} when is_integer(status) ->
        Logger.warning("harness run: test DB teardown exited #{status}: #{String.trim(output)}")
        :ok
    end
  end

  def teardown(%Project{}, _worktree_path, _run_id, _env), do: :ok

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
  defp config_mentions_env?(test_config, env_name) do
    case File.read(test_config) do
      {:ok, config} -> String.contains?(config, env_name)
      {:error, _reason} -> false
    end
  end

  @spec run_drop(String.t(), [{String.t(), String.t()}]) :: {String.t(), non_neg_integer()} | {:error, term()}
  defp run_drop(worktree_path, env) do
    System.cmd("mix", @drop_args, cd: worktree_path, env: env, stderr_to_stdout: true)
  rescue
    e in ErlangError -> {:error, e.original}
  end
end
