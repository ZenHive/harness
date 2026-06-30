defmodule Harness.DepFreshness.Provider.Elixir do
  @moduledoc """
  Elixir dependency freshness via `mix hex.outdated`.

  Parses the CLI table mechanically — Up-to-date / Update possible /
  Update not possible — and records constraint allowance from the status column.
  """

  @behaviour Harness.DepFreshness.Provider

  alias Harness.DepFreshness.Row
  alias Harness.Project

  @table_header ~r/^Dependency\s+Only\s+Current\s+Latest\s+Status/

  @impl Harness.DepFreshness.Provider
  @spec scan(Project.t(), String.t(), keyword()) ::
          {:ok, [Row.t()]} | {:error, term()} | {:skipped, term()}
  def scan(_project, repo_path, opts) when is_binary(repo_path) and is_list(opts) do
    runner = runner(opts)

    with :ok <- ensure_mix_project(repo_path),
         :ok <- ensure_deps(repo_path, runner),
         {:ok, output} <- runner.("mix", ["hex.outdated"], repo_path) do
      parse_output(output)
    end
  end

  @doc false
  @spec parse_output(String.t()) :: {:ok, [Row.t()]} | {:error, {:parse_failed, String.t()}}
  def parse_output(output) when is_binary(output) do
    lines = String.split(output, "\n")

    if Enum.any?(lines, &table_header?/1) do
      rows =
        lines
        |> Enum.drop_while(fn line -> not table_header?(line) end)
        |> Enum.drop(1)
        |> Enum.take_while(&data_row?/1)
        |> Enum.map(&parse_row/1)
        |> Enum.reject(&is_nil/1)

      {:ok, rows}
    else
      {:error, {:parse_failed, output}}
    end
  end

  @spec runner(keyword()) :: (String.t(), [String.t()], String.t() -> {:ok, String.t()} | {:error, term()})
  defp runner(opts) do
    Keyword.get(opts, :runner) ||
      Application.get_env(:harness, :dep_freshness_runner) ||
      (&default_runner/3)
  end

  @spec ensure_mix_project(String.t()) :: :ok | {:skipped, :missing_mix_exs}
  defp ensure_mix_project(repo_path) do
    if File.exists?(Path.join(repo_path, "mix.exs")), do: :ok, else: {:skipped, :missing_mix_exs}
  end

  @spec ensure_deps(String.t(), (String.t(), [String.t()], String.t() -> {:ok, String.t()} | {:error, term()})) ::
          :ok | {:error, term()}
  defp ensure_deps(repo_path, runner) do
    deps_dir = Path.join(repo_path, "deps")

    if File.dir?(deps_dir) do
      :ok
    else
      case runner.("mix", ["deps.get", "--quiet"], repo_path) do
        {:ok, _output} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec default_runner(String.t(), [String.t()], String.t()) :: {:ok, String.t()} | {:error, term()}
  defp default_runner("mix", args, cwd) do
    case System.cmd("mix", args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, exit} -> route_command_exit(args, exit, output)
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp default_runner(cmd, _args, _cwd), do: {:error, {:unsupported_command, cmd}}

  @spec route_command_exit([String.t()], integer(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp route_command_exit(["hex.outdated"], _exit, output), do: {:ok, output}
  defp route_command_exit(args, exit, output), do: {:error, {:command_failed, args, exit, output}}

  @spec table_header?(String.t()) :: boolean()
  defp table_header?(line), do: String.match?(line, @table_header)

  @spec data_row?(String.t()) :: boolean()
  defp data_row?(line) do
    trimmed = String.trim(line)

    trimmed != "" and not String.starts_with?(trimmed, "Run `mix hex.outdated") and
      not String.starts_with?(trimmed, "To view the diffs")
  end

  @spec parse_row(String.t()) :: Row.t() | nil
  defp parse_row(line) do
    parts = String.split(String.trim(line), ~r/\s{2,}/, trim: true)

    case parts do
      [name, current, latest, status] ->
        build_row(name, current, latest, status)

      [name, _only, current, latest, status] ->
        build_row(name, current, latest, status)

      _other ->
        nil
    end
  end

  @spec build_row(String.t(), String.t(), String.t(), String.t()) :: Row.t()
  defp build_row(name, current, latest, status) do
    %Row{
      name: name,
      current_version: current,
      latest_version: latest,
      constraint_allowed: constraint_allowed?(status)
    }
  end

  @spec constraint_allowed?(String.t()) :: boolean()
  defp constraint_allowed?("Update not possible" <> _), do: false
  defp constraint_allowed?(_status), do: true
end
