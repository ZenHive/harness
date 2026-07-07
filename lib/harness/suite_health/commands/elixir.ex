defmodule Harness.SuiteHealth.Commands.Elixir do
  @moduledoc false

  alias Harness.Project

  @test_args ~w(test.json --quiet --all --include integration)

  @doc false
  @spec command(Project.t(), String.t()) :: {:ok, {String.t(), [String.t()]}} | {:skipped, term()}
  def command(_project, repo_path) when is_binary(repo_path) do
    if File.exists?(Path.join(repo_path, "mix.exs")) do
      {:ok, {"mix", @test_args}}
    else
      {:skipped, :missing_mix_exs}
    end
  end
end
