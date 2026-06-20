defmodule Harness.Run.TestDbIsolation do
  @moduledoc """
  Mechanical per-run test database partitioning for agent-gate runs.

  Harness only sets the environment variable that Phoenix/Ecto projects already
  conventionally read from `config/test.exs`. The reviewer still runs the
  project's checks and remains the gate.
  """

  alias Harness.Project

  require Logger

  @default_env "MIX_TEST_PARTITION"
  @suffix_prefix "_h_"
  @drop_args ["ecto.drop", "--quiet"]

  @doc false
  @spec env(Project.t(), String.t()) :: %{optional(String.t()) => String.t() | false}
  def env(%Project{} = project, run_id) when is_binary(run_id) do
    case env_name(project) do
      {:ok, name} -> %{name => partition_suffix(run_id)}
      :disabled -> %{@default_env => false}
    end
  end

  @doc false
  @spec teardown(Project.t(), String.t() | nil, String.t()) :: :ok
  def teardown(%Project{} = project, worktree_path, run_id) when is_binary(worktree_path) and is_binary(run_id) do
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

  def teardown(%Project{}, _worktree_path, _run_id), do: :ok

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
