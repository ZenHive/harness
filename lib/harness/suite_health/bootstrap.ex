defmodule Harness.SuiteHealth.Bootstrap do
  @moduledoc false

  alias Harness.Project
  alias Harness.Run.TestDbIsolation

  @health_partition "_h_suite_health"
  @ecto_create_args ~w(ecto.create --quiet)
  @ecto_migrate_args ~w(ecto.migrate --quiet)
  @deps_get_args ~w(deps.get --quiet)

  @doc "Prepares a cold worktree for the language-derived full-suite run."
  @spec prepare(Project.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def prepare(%Project{} = project, worktree_path, opts \\ []) when is_binary(worktree_path) do
    runner = runner(opts)
    maybe_bootstrap_elixir(project, worktree_path, runner)
  end

  @spec maybe_bootstrap_elixir(Project.t(), String.t(), runner()) :: :ok | {:error, term()}
  defp maybe_bootstrap_elixir(%Project{} = project, worktree_path, runner) do
    if File.exists?(Path.join(worktree_path, "mix.exs")) do
      with :ok <- ensure_deps(worktree_path, runner) do
        ensure_test_database(project, worktree_path, runner)
      end
    else
      :ok
    end
  end

  @type runner :: (String.t(), [String.t()], String.t(), keyword() -> {String.t(), non_neg_integer()})

  @spec runner(keyword()) :: runner()
  defp runner(opts) do
    Keyword.get(opts, :runner) ||
      Application.get_env(:harness, :suite_health_runner) ||
      (&default_runner/4)
  end

  @spec ensure_deps(String.t(), runner()) :: :ok | {:error, term()}
  defp ensure_deps(worktree_path, runner) do
    if File.dir?(Path.join(worktree_path, "deps")) do
      :ok
    else
      case runner.("mix", @deps_get_args, worktree_path, []) do
        {_output, 0} -> :ok
        {output, exit} -> {:error, {:deps_get_failed, exit, output}}
      end
    end
  end

  @spec ensure_test_database(Project.t(), String.t(), runner()) :: :ok | {:error, term()}
  defp ensure_test_database(%Project{} = project, worktree_path, runner) do
    if ecto_test_project?(worktree_path) do
      env = test_env(project)

      with {_output, 0} <- runner.("mix", @ecto_create_args, worktree_path, env),
           {_output, 0} <- runner.("mix", @ecto_migrate_args, worktree_path, env) do
        :ok
      else
        {output, exit} -> {:error, {:ecto_bootstrap_failed, exit, output}}
      end
    else
      :ok
    end
  end

  @spec ecto_test_project?(String.t()) :: boolean()
  # sobelow_skip ["Traversal.FileModule"] — `worktree_path` is a harness-managed checkout.
  defp ecto_test_project?(worktree_path) do
    test_config = Path.join(worktree_path, "config/test.exs")

    with true <- File.regular?(test_config),
         {:ok, contents} <- File.read(test_config) do
      String.contains?(contents, "Ecto")
    else
      _ -> false
    end
  end

  @spec test_env(Project.t()) :: keyword()
  defp test_env(%Project{} = project) do
    base = [{"MIX_ENV", "test"}]

    case TestDbIsolation.env_name(project) do
      {:ok, name} -> base ++ [{name, @health_partition}]
      :disabled -> base
    end
  end

  @doc false
  # sobelow_skip ["CI.System"] — argv-list spawn for language-derived suite commands.
  @spec default_runner(String.t(), [String.t()], String.t(), keyword()) :: {String.t(), non_neg_integer()}
  def default_runner(cmd, args, cwd, env) do
    System.cmd(cmd, args, cd: cwd, env: env, stderr_to_stdout: true)
  rescue
    _e in ErlangError -> {"", 127}
  end
end
