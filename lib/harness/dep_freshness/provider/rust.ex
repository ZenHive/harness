defmodule Harness.DepFreshness.Provider.Rust do
  @moduledoc """
  Rust dependency freshness via `cargo outdated --format json -R`.

  `cargo outdated` is provided by the third-party `cargo-outdated` crate, not by
  Cargo itself. The default runner first tries the Cargo subcommand and, if it is
  missing, installs `cargo-outdated` under `/tmp/harness-cargo-outdated` and runs
  that local binary directly.
  """

  @behaviour Harness.DepFreshness.Provider

  alias Harness.DepFreshness.Row
  alias Harness.Project

  @cargo_toml "Cargo.toml"
  @cargo_outdated_args ["outdated", "--format", "json", "-R"]
  @cargo_outdated_version_args ["outdated", "--version"]
  @install_args ["install", "cargo-outdated", "--locked", "--root"]

  @impl Harness.DepFreshness.Provider
  @spec scan(Project.t(), String.t(), keyword()) ::
          {:ok, [Row.t()]} | {:error, term()} | {:skipped, term()}
  def scan(_project, repo_path, opts) when is_binary(repo_path) and is_list(opts) do
    runner = runner(opts)

    with :ok <- ensure_cargo_project(repo_path),
         {:ok, {cmd, args}} <- resolve_outdated_command(repo_path, runner),
         {:ok, output} <- runner.(cmd, args, repo_path) do
      parse_output(output)
    end
  end

  @doc false
  @spec parse_output(String.t()) :: {:ok, [Row.t()]} | {:error, {:parse_failed, String.t()}}
  def parse_output(output) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, %{"dependencies" => dependencies}} when is_list(dependencies) ->
        rows = dependencies |> Enum.map(&row_from_dependency/1) |> Enum.reject(&is_nil/1)
        {:ok, rows}

      _other ->
        {:error, {:parse_failed, output}}
    end
  end

  @spec runner(keyword()) :: (String.t(), [String.t()], String.t() -> {:ok, String.t()} | {:error, term()})
  defp runner(opts) do
    Keyword.get(opts, :runner) ||
      Application.get_env(:harness, :dep_freshness_runner) ||
      (&default_runner/3)
  end

  @spec ensure_cargo_project(String.t()) :: :ok | {:skipped, :missing_cargo_toml}
  defp ensure_cargo_project(repo_path) do
    if File.exists?(Path.join(repo_path, @cargo_toml)), do: :ok, else: {:skipped, :missing_cargo_toml}
  end

  @spec resolve_outdated_command(
          String.t(),
          (String.t(), [String.t()], String.t() -> {:ok, String.t()} | {:error, term()})
        ) ::
          {:ok, {String.t(), [String.t()]}} | {:error, term()}
  defp resolve_outdated_command(repo_path, runner) do
    case runner.("cargo", @cargo_outdated_version_args, repo_path) do
      {:ok, _output} -> {:ok, {"cargo", @cargo_outdated_args}}
      {:error, _reason} -> resolve_local_outdated_command(repo_path, runner)
    end
  end

  @spec resolve_local_outdated_command(
          String.t(),
          (String.t(), [String.t()], String.t() -> {:ok, String.t()} | {:error, term()})
        ) ::
          {:ok, {String.t(), [String.t()]}} | {:error, term()}
  defp resolve_local_outdated_command(repo_path, runner) do
    binary = cargo_outdated_binary()

    case runner.(binary, @cargo_outdated_version_args, repo_path) do
      {:ok, _output} ->
        {:ok, {binary, @cargo_outdated_args}}

      {:error, _reason} ->
        install_local_cargo_outdated(repo_path, runner, binary)
    end
  end

  @spec install_local_cargo_outdated(
          String.t(),
          (String.t(), [String.t()], String.t() -> {:ok, String.t()} | {:error, term()}),
          String.t()
        ) ::
          {:ok, {String.t(), [String.t()]}} | {:error, term()}
  defp install_local_cargo_outdated(repo_path, runner, binary) do
    case runner.("cargo", @install_args ++ [install_root()], repo_path) do
      {:ok, _output} -> {:ok, {binary, @cargo_outdated_args}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec default_runner(String.t(), [String.t()], String.t()) :: {:ok, String.t()} | {:error, term()}
  defp default_runner(cmd, args, cwd) do
    case System.cmd(cmd, args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, exit} -> {:error, {:command_failed, cmd, args, exit, output}}
    end
  rescue
    error in ErlangError -> {:error, {:command_unavailable, cmd, Exception.message(error)}}
  catch
    :exit, reason -> {:error, reason}
  end

  @spec row_from_dependency(term()) :: Row.t() | nil
  defp row_from_dependency(%{"name" => name, "project" => current, "latest" => latest} = dependency)
       when is_binary(name) and is_binary(current) and is_binary(latest) do
    %Row{
      name: name,
      current_version: current,
      latest_version: latest,
      constraint_allowed: constraint_allowed?(current, latest, Map.get(dependency, "compat"))
    }
  end

  defp row_from_dependency(_dependency), do: nil

  @spec constraint_allowed?(String.t(), String.t(), term()) :: boolean()
  defp constraint_allowed?(current, latest, _compat) when current == latest, do: true
  defp constraint_allowed?(_current, latest, compat) when is_binary(compat), do: compat == latest
  defp constraint_allowed?(_current, _latest, _compat), do: false

  @spec cargo_outdated_binary() :: String.t()
  defp cargo_outdated_binary, do: Path.join([install_root(), "bin", "cargo-outdated"])

  @spec install_root() :: String.t()
  defp install_root, do: Path.join(System.tmp_dir!(), "harness-cargo-outdated")
end
