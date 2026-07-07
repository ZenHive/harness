defmodule Harness.DepFreshness.Provider.Go do
  @moduledoc """
  Go dependency freshness via `go list -mod=readonly -m -u -json all`.

  The provider reads committed module metadata, asks the Go tool for raw module
  update facts, and records rows without running upgrade commands.
  """

  @behaviour Harness.DepFreshness.Provider

  alias Harness.DepFreshness.Row
  alias Harness.Project

  @go_mod "go.mod"
  @command_args ["list", "-mod=readonly", "-m", "-u", "-json", "all"]
  @module_path_with_major ~r/\/v(?<major>[2-9][0-9]*)$/
  @version_major ~r/^v(?<major>0|[1-9][0-9]*)\./

  @impl Harness.DepFreshness.Provider
  @spec scan(Project.t(), String.t(), keyword()) ::
          {:ok, [Row.t()]} | {:error, term()} | {:skipped, term()}
  def scan(_project, repo_path, opts) when is_binary(repo_path) and is_list(opts) do
    runner = runner(opts)

    with {:ok, requirements} <- read_requirements(repo_path),
         {:ok, output} <- runner.("go", @command_args, repo_path) do
      parse_output(output, requirements)
    end
  end

  @doc false
  @spec parse_output(String.t(), %{String.t() => String.t()}) ::
          {:ok, [Row.t()]} | {:error, {:parse_failed, String.t()}}
  def parse_output(output, requirements) when is_binary(output) and is_map(requirements) do
    case decode_module_stream(output) do
      {:ok, modules} ->
        rows = modules |> Enum.map(&row_from_module(&1, requirements)) |> Enum.reject(&is_nil/1)
        {:ok, rows}

      {:error, _reason} ->
        {:error, {:parse_failed, output}}
    end
  end

  @doc false
  @spec parse_requirements(String.t()) :: %{String.t() => String.t()}
  def parse_requirements(content) when is_binary(content) do
    content
    |> String.split("\n")
    |> Enum.reduce({false, %{}}, &collect_requirement/2)
    |> elem(1)
  end

  @spec runner(keyword()) :: (String.t(), [String.t()], String.t() -> {:ok, String.t()} | {:error, term()})
  defp runner(opts) do
    Keyword.get(opts, :runner) ||
      Application.get_env(:harness, :dep_freshness_runner) ||
      (&default_runner/3)
  end

  @spec read_requirements(String.t()) :: {:ok, %{String.t() => String.t()}} | {:skipped, term()}
  defp read_requirements(repo_path) do
    path = Path.join(repo_path, @go_mod)

    if File.exists?(path) do
      {:ok, path |> File.stream!(:line, []) |> Enum.join() |> parse_requirements()}
    else
      {:skipped, :missing_go_mod}
    end
  rescue
    error in File.Error -> {:skipped, {:go_mod_unreadable, error.reason}}
  end

  @spec default_runner(String.t(), [String.t()], String.t()) :: {:ok, String.t()} | {:error, term()}
  defp default_runner("go", args, cwd) do
    case System.cmd("go", args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, exit} -> {:error, {:command_failed, "go", args, exit, output}}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp default_runner(cmd, _args, _cwd), do: {:error, {:unsupported_command, cmd}}

  @spec decode_module_stream(String.t()) :: {:ok, [map()]} | {:error, term()}
  defp decode_module_stream(output) do
    wrapped =
      output
      |> String.trim()
      |> String.replace(~r/}\s*{/, "},{")
      |> then(&("[" <> &1 <> "]"))

    case Jason.decode(wrapped) do
      {:ok, modules} when is_list(modules) -> {:ok, modules}
      other -> other
    end
  end

  @spec row_from_module(map(), %{String.t() => String.t()}) :: Row.t() | nil
  defp row_from_module(%{"Main" => true}, _requirements), do: nil

  defp row_from_module(%{"Path" => path, "Version" => current} = module, requirements)
       when is_binary(path) and is_binary(current) do
    latest = module |> Map.get("Update", %{}) |> version_from_update(current)

    %Row{
      name: path,
      current_version: current,
      latest_version: latest,
      constraint_allowed: constraint_allowed?(path, current, latest, Map.get(requirements, path))
    }
  end

  defp row_from_module(_module, _requirements), do: nil

  @spec version_from_update(term(), String.t()) :: String.t()
  defp version_from_update(%{"Version" => latest}, _current) when is_binary(latest), do: latest
  defp version_from_update(_update, current), do: current

  @spec constraint_allowed?(String.t(), String.t(), String.t(), String.t() | nil) :: boolean()
  defp constraint_allowed?(_path, current, latest, _declared) when current == latest, do: true

  defp constraint_allowed?(path, _current, latest, declared) when is_binary(declared) do
    compatible_module_major?(path, latest)
  end

  defp constraint_allowed?(_path, _current, _latest, _declared), do: false

  @spec compatible_module_major?(String.t(), String.t()) :: boolean()
  defp compatible_module_major?(path, version) do
    case {module_major(path), version_major(version)} do
      {nil, major} when major in [0, 1] -> true
      {module_major, module_major} when is_integer(module_major) -> true
      _other -> false
    end
  end

  @spec module_major(String.t()) :: non_neg_integer() | nil
  defp module_major(path) do
    case Regex.named_captures(@module_path_with_major, path) do
      %{"major" => major} -> String.to_integer(major)
      _other -> nil
    end
  end

  @spec version_major(String.t()) :: non_neg_integer() | nil
  defp version_major(version) do
    case Regex.named_captures(@version_major, version) do
      %{"major" => major} -> String.to_integer(major)
      _other -> nil
    end
  end

  @spec collect_requirement(String.t(), {boolean(), %{String.t() => String.t()}}) ::
          {boolean(), %{String.t() => String.t()}}
  defp collect_requirement(line, {in_require_block?, requirements}) do
    line
    |> strip_line_comment()
    |> String.trim()
    |> collect_trimmed_requirement(in_require_block?, requirements)
  end

  @spec collect_trimmed_requirement(String.t(), boolean(), %{String.t() => String.t()}) ::
          {boolean(), %{String.t() => String.t()}}
  defp collect_trimmed_requirement("require (", _in_require_block?, requirements), do: {true, requirements}
  defp collect_trimmed_requirement(")", true, requirements), do: {false, requirements}

  defp collect_trimmed_requirement("require " <> requirement, false, requirements) do
    {false, put_requirement(requirements, requirement)}
  end

  defp collect_trimmed_requirement(requirement, true, requirements) do
    {true, put_requirement(requirements, requirement)}
  end

  defp collect_trimmed_requirement(_line, in_require_block?, requirements), do: {in_require_block?, requirements}

  @spec put_requirement(%{String.t() => String.t()}, String.t()) :: %{String.t() => String.t()}
  defp put_requirement(requirements, requirement) do
    case String.split(requirement, ~r/\s+/, trim: true) do
      [path, version | _rest] -> Map.put(requirements, path, version)
      _other -> requirements
    end
  end

  @spec strip_line_comment(String.t()) :: String.t()
  defp strip_line_comment(line) do
    line
    |> String.split("//", parts: 2)
    |> List.first()
  end
end
