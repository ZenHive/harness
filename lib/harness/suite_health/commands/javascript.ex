defmodule Harness.SuiteHealth.Commands.JavaScript do
  @moduledoc false

  alias Harness.Project

  @doc false
  # sobelow_skip ["Traversal.FileModule"] — `repo_path` is a registered project checkout.
  @spec command(Project.t(), String.t()) :: {:ok, {String.t(), [String.t()]}} | {:skipped, term()}
  def command(_project, repo_path) when is_binary(repo_path) do
    package_json = Path.join(repo_path, "package.json")

    with true <- File.exists?(package_json),
         {:ok, contents} <- File.read(package_json),
         {:ok, %{"scripts" => %{"test" => _}}} <- Jason.decode(contents) do
      {:ok, {"npm", ["test"]}}
    else
      false -> {:skipped, :missing_package_json}
      {:ok, _} -> {:skipped, :missing_test_script}
      {:error, reason} -> {:skipped, {:package_json_read_failed, reason}}
    end
  end
end
