defmodule Harness.SuiteHealth.Commands.Rust do
  @moduledoc false

  alias Harness.Project

  @doc false
  @spec command(Project.t(), String.t()) :: {:ok, {String.t(), [String.t()]}} | {:skipped, term()}
  def command(_project, repo_path) when is_binary(repo_path) do
    if File.exists?(Path.join(repo_path, "Cargo.toml")) do
      {:ok, {"cargo", ["test"]}}
    else
      {:skipped, :missing_cargo_toml}
    end
  end
end
