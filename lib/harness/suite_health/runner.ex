defmodule Harness.SuiteHealth.Runner do
  @moduledoc false

  alias Harness.Project
  alias Harness.Run.TestDbIsolation
  alias Harness.SuiteHealth.Bootstrap
  alias Harness.SuiteHealth.Commands
  alias Harness.SuiteHealth.Parser
  alias Harness.SuiteHealth.Result

  @health_partition "_h_suite_health"

  @doc "Runs language-derived full-suite commands in `worktree_path` and returns a witness."
  @spec run_suite(Project.t(), String.t(), String.t(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def run_suite(%Project{} = project, worktree_path, base_sha, opts \\ [])
      when is_binary(worktree_path) and is_binary(base_sha) do
    runner = runner(opts)
    languages = language_label(project.languages)

    with :ok <- Bootstrap.prepare(project, worktree_path, runner: runner),
         {:ok, commands} <- resolve_commands(project, worktree_path),
         {:ok, aggregate} <- run_commands(project, worktree_path, commands, runner) do
      {:ok,
       Result.build(project.name,
         checked_at: Keyword.get(opts, :checked_at, DateTime.utc_now(:millisecond)),
         passed: aggregate.passed,
         exit_code: aggregate.exit_code,
         command: aggregate.command,
         base_sha: base_sha,
         failing_tests: aggregate.failing_tests,
         languages: languages
       )}
    end
  end

  @type aggregate :: %{
          passed: boolean(),
          exit_code: non_neg_integer(),
          command: String.t(),
          failing_tests: [map()]
        }

  @spec resolve_commands(Project.t(), String.t()) :: {:ok, [{atom(), {String.t(), [String.t()]}}]} | {:error, term()}
  defp resolve_commands(%Project{} = project, worktree_path) do
    commands =
      project
      |> Commands.resolve()
      |> Enum.flat_map(fn
        {:ok, language, provider} ->
          case provider.command(project, worktree_path) do
            {:ok, command} -> [{language, command}]
            {:skipped, _reason} -> []
          end

        {:skipped, _language, _reason} ->
          []
      end)

    if commands == [] do
      {:error, :no_suite_commands}
    else
      {:ok, commands}
    end
  end

  @spec run_commands(Project.t(), String.t(), [{atom(), {String.t(), [String.t()]}}], Bootstrap.runner()) ::
          {:ok, aggregate()} | {:error, term()}
  defp run_commands(project, worktree_path, commands, runner) do
    commands
    |> Enum.reduce_while({true, 0, [], []}, fn {_language, command}, {passed?, exit_code, failures, labels} ->
      {output, status} = invoke_command(project, worktree_path, command, runner)
      cmd_label = command_label(command)
      test_failures = Parser.failing_tests(output, command)
      cmd_passed? = Parser.passed?(output, command, status)

      if cmd_passed? do
        {:cont, {passed? and cmd_passed?, max(exit_code, status), failures ++ test_failures, labels ++ [cmd_label]}}
      else
        {:cont, {false, max(exit_code, status), failures ++ test_failures, labels ++ [cmd_label]}}
      end
    end)
    |> case do
      {passed?, exit_code, failures, labels} ->
        {:ok,
         %{
           passed: passed?,
           exit_code: exit_code,
           command: Enum.join(labels, " && "),
           failing_tests: failures
         }}
    end
  end

  @spec invoke_command(Project.t(), String.t(), {String.t(), [String.t()]}, Bootstrap.runner()) ::
          {String.t(), non_neg_integer()}
  defp invoke_command(%Project{} = project, worktree_path, {cmd, args}, runner) do
    env = command_env(project, cmd)
    runner.(cmd, args, worktree_path, env)
  end

  @spec command_env(Project.t(), String.t()) :: keyword()
  defp command_env(%Project{} = project, "mix") do
    base = [{"MIX_ENV", "test"}]

    case TestDbIsolation.env_name(project) do
      {:ok, name} -> base ++ [{name, @health_partition}]
      :disabled -> base
    end
  end

  defp command_env(_project, _cmd), do: []

  @spec command_label({String.t(), [String.t()]}) :: String.t()
  defp command_label({cmd, args}), do: Enum.join([cmd | args], " ")

  @spec runner(keyword()) :: Bootstrap.runner()
  defp runner(opts) do
    Keyword.get(opts, :runner) ||
      Application.get_env(:harness, :suite_health_runner) ||
      (&Bootstrap.default_runner/4)
  end

  @spec language_label([atom()]) :: String.t()
  defp language_label(languages), do: Enum.map_join(languages, ",", &Atom.to_string/1)
end
