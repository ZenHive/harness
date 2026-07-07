defmodule Harness.DepFreshness.Provider.JavaScript do
  @moduledoc """
  JavaScript dependency freshness via npm, pnpm, or yarn outdated metadata.

  Detects the package manager from committed package metadata, runs the matching
  read-only outdated command, and records raw current/wanted/latest facts.
  """

  @behaviour Harness.DepFreshness.Provider

  alias Harness.DepFreshness.Row
  alias Harness.Project

  @package_json "package.json"
  @outdated_found_exit 1
  @dependency_fields ~w(dependencies devDependencies optionalDependencies peerDependencies)
  @lockfiles [
    {"package-lock.json", :npm},
    {"npm-shrinkwrap.json", :npm},
    {"pnpm-lock.yaml", :pnpm},
    {"yarn.lock", :yarn}
  ]
  @commands %{
    npm: ["outdated", "--json"],
    pnpm: ["outdated", "--format", "json"],
    yarn: ["outdated", "--json"]
  }
  @exact_version ~r/^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$/

  @impl Harness.DepFreshness.Provider
  @spec scan(Project.t(), String.t(), keyword()) ::
          {:ok, [Row.t()]} | {:error, term()} | {:skipped, term()}
  def scan(_project, repo_path, opts) when is_binary(repo_path) and is_list(opts) do
    runner = runner(opts)

    with {:ok, manifest} <- read_manifest(repo_path),
         {:ok, manager} <- detect_package_manager(repo_path, manifest),
         {:ok, output} <- runner.(Atom.to_string(manager), Map.fetch!(@commands, manager), repo_path) do
      parse_output(manager, output, dependency_constraints(manifest))
    end
  end

  @doc false
  @spec detect_package_manager(String.t(), map()) :: {:ok, :npm | :pnpm | :yarn} | {:skipped, term()}
  def detect_package_manager(repo_path, manifest) when is_binary(repo_path) and is_map(manifest) do
    case package_manager_field(manifest) do
      {:ok, manager} -> {:ok, manager}
      {:skipped, reason} -> {:skipped, reason}
      :missing -> detect_lockfile_manager(repo_path)
    end
  end

  @doc false
  @spec parse_output(:npm | :pnpm | :yarn, String.t(), %{String.t() => String.t()}) ::
          {:ok, [Row.t()]} | {:error, {:parse_failed, String.t()}}
  def parse_output(manager, output, constraints) when is_binary(output) and is_map(constraints) do
    trimmed = String.trim(output)

    cond do
      trimmed == "" ->
        {:ok, []}

      manager == :yarn ->
        parse_yarn_or_json(trimmed, constraints)

      true ->
        parse_json_rows(trimmed, constraints)
    end
  end

  @spec runner(keyword()) :: (String.t(), [String.t()], String.t() -> {:ok, String.t()} | {:error, term()})
  defp runner(opts) do
    Keyword.get(opts, :runner) ||
      Application.get_env(:harness, :dep_freshness_runner) ||
      (&default_runner/3)
  end

  @spec read_manifest(String.t()) :: {:ok, map()} | {:skipped, term()}
  defp read_manifest(repo_path) do
    path = Path.join(repo_path, @package_json)

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, manifest} when is_map(manifest) <- Jason.decode(content) do
      {:ok, manifest}
    else
      false -> {:skipped, :missing_package_json}
      {:error, %Jason.DecodeError{} = error} -> {:skipped, {:invalid_package_json, Exception.message(error)}}
      {:error, reason} -> {:skipped, {:package_json_unreadable, reason}}
      {:ok, _other} -> {:skipped, :invalid_package_json}
    end
  end

  @spec package_manager_field(map()) :: {:ok, :npm | :pnpm | :yarn} | {:skipped, term()} | :missing
  defp package_manager_field(%{"packageManager" => value}) when is_binary(value) do
    case String.split(value, "@", parts: 2) do
      [manager, _version] when manager in ~w(npm pnpm yarn) -> {:ok, String.to_existing_atom(manager)}
      [manager, _version] -> {:skipped, {:unsupported_package_manager, manager}}
      _other -> {:skipped, {:invalid_package_manager, value}}
    end
  end

  defp package_manager_field(_manifest), do: :missing

  @spec detect_lockfile_manager(String.t()) :: {:ok, :npm | :pnpm | :yarn} | {:skipped, term()}
  defp detect_lockfile_manager(repo_path) do
    managers =
      @lockfiles
      |> Enum.filter(fn {file, _manager} -> File.exists?(Path.join(repo_path, file)) end)
      |> Enum.map(fn {_file, manager} -> manager end)
      |> Enum.uniq()

    case managers do
      [manager] -> {:ok, manager}
      [] -> {:skipped, :missing_package_manager_metadata}
      managers -> {:skipped, {:ambiguous_package_manager, managers}}
    end
  end

  @spec dependency_constraints(map()) :: %{String.t() => String.t()}
  defp dependency_constraints(manifest) do
    @dependency_fields
    |> Enum.flat_map(&dependency_entries(manifest, &1))
    |> Map.new()
  end

  @spec dependency_entries(map(), String.t()) :: [{String.t(), String.t()}]
  defp dependency_entries(manifest, field) do
    case Map.get(manifest, field) do
      deps when is_map(deps) ->
        deps
        |> Enum.filter(fn {name, constraint} -> is_binary(name) and is_binary(constraint) end)
        |> Enum.map(fn {name, constraint} -> {name, constraint} end)

      _other ->
        []
    end
  end

  @spec default_runner(String.t(), [String.t()], String.t()) :: {:ok, String.t()} | {:error, term()}
  defp default_runner(cmd, args, cwd) do
    case System.cmd(cmd, args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, @outdated_found_exit} -> {:ok, output}
      {output, exit} -> {:error, {:command_failed, cmd, args, exit, output}}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @spec parse_yarn_or_json(String.t(), %{String.t() => String.t()}) ::
          {:ok, [Row.t()]} | {:error, {:parse_failed, String.t()}}
  defp parse_yarn_or_json(output, constraints) do
    case parse_json_rows(output, constraints) do
      {:ok, rows} -> {:ok, rows}
      {:error, _reason} -> parse_yarn_lines(output, constraints)
    end
  end

  @spec parse_json_rows(String.t(), %{String.t() => String.t()}) ::
          {:ok, [Row.t()]} | {:error, {:parse_failed, String.t()}}
  defp parse_json_rows(output, constraints) do
    case Jason.decode(output) do
      {:ok, map} when map == %{} ->
        {:ok, []}

      {:ok, map} when is_map(map) ->
        rows = map |> Enum.map(&row_from_named_entry(&1, constraints)) |> Enum.reject(&is_nil/1)
        rows_result(output, map, rows)

      {:ok, list} when is_list(list) ->
        rows = list |> Enum.map(&row_from_map(&1, constraints)) |> Enum.reject(&is_nil/1)
        rows_result(output, list, rows)

      _other ->
        {:error, {:parse_failed, output}}
    end
  end

  @spec parse_yarn_lines(String.t(), %{String.t() => String.t()}) ::
          {:ok, [Row.t()]} | {:error, {:parse_failed, String.t()}}
  defp parse_yarn_lines(output, constraints) do
    rows =
      output
      |> String.split("\n", trim: true)
      |> Enum.flat_map(&rows_from_yarn_line(&1, constraints))

    if rows == [], do: {:error, {:parse_failed, output}}, else: {:ok, rows}
  end

  @spec rows_from_yarn_line(String.t(), %{String.t() => String.t()}) :: [Row.t()]
  defp rows_from_yarn_line(line, constraints) do
    case Jason.decode(line) do
      {:ok, %{"type" => "table", "data" => %{"head" => head, "body" => body}}}
      when is_list(head) and is_list(body) ->
        body |> Enum.map(&row_from_yarn_table(head, &1, constraints)) |> Enum.reject(&is_nil/1)

      _other ->
        []
    end
  end

  @spec row_from_named_entry({String.t(), term()}, %{String.t() => String.t()}) :: Row.t() | nil
  defp row_from_named_entry({name, facts}, constraints) when is_binary(name) and is_map(facts) do
    row_from_map(Map.put(facts, "name", name), constraints)
  end

  defp row_from_named_entry(_entry, _constraints), do: nil

  @spec row_from_map(term(), %{String.t() => String.t()}) :: Row.t() | nil
  defp row_from_map(%{} = facts, constraints) do
    name = string_value(facts, ["name", "package", "Package"])
    current = string_value(facts, ["current", "currentVersion", "Current"])
    latest = string_value(facts, ["latest", "latestVersion", "Latest"])
    wanted = string_value(facts, ["wanted", "wantedVersion", "Wanted"])

    build_row(name, current, latest, wanted, constraints)
  end

  defp row_from_map(_facts, _constraints), do: nil

  @spec rows_result(String.t(), map() | list(), [Row.t()]) :: {:ok, [Row.t()]} | {:error, {:parse_failed, String.t()}}
  defp rows_result(_output, source, rows) when source in [%{}, []], do: {:ok, rows}
  defp rows_result(_output, _source, [_row | _rest] = rows), do: {:ok, rows}
  defp rows_result(output, _source, []), do: {:error, {:parse_failed, output}}

  @spec row_from_yarn_table([term()], [term()], %{String.t() => String.t()}) :: Row.t() | nil
  defp row_from_yarn_table(head, row, constraints) when is_list(row) do
    cells = head |> Enum.zip(row) |> Map.new(fn {key, value} -> {normalize_head(key), version_string(value)} end)

    build_row(
      Map.get(cells, "package"),
      Map.get(cells, "current"),
      Map.get(cells, "latest"),
      Map.get(cells, "wanted"),
      constraints
    )
  end

  defp row_from_yarn_table(_head, _row, _constraints), do: nil

  @spec build_row(
          String.t() | nil,
          String.t() | nil,
          String.t() | nil,
          String.t() | nil,
          %{String.t() => String.t()}
        ) ::
          Row.t() | nil
  defp build_row(name, current, latest, wanted, constraints)
       when is_binary(name) and is_binary(current) and is_binary(latest) do
    %Row{
      name: name,
      current_version: current,
      latest_version: latest,
      constraint_allowed: constraint_allowed?(wanted, latest, current, Map.get(constraints, name))
    }
  end

  defp build_row(_name, _current, _latest, _wanted, _constraints), do: nil

  @spec constraint_allowed?(String.t() | nil, String.t(), String.t(), String.t() | nil) :: boolean()
  defp constraint_allowed?(wanted, latest, _current, _constraint) when is_binary(wanted), do: wanted == latest
  defp constraint_allowed?(_wanted, latest, current, _constraint) when latest == current, do: true

  defp constraint_allowed?(_wanted, latest, _current, constraint) when is_binary(constraint),
    do: exact_version?(constraint) and latest == constraint

  defp constraint_allowed?(_wanted, _latest, _current, _constraint), do: false

  @spec exact_version?(String.t()) :: boolean()
  defp exact_version?(constraint), do: String.match?(constraint, @exact_version)

  @spec string_value(map(), [String.t()]) :: String.t() | nil
  defp string_value(map, keys) do
    keys
    |> Enum.find_value(&Map.get(map, &1))
    |> version_string()
  end

  @spec version_string(term()) :: String.t() | nil
  defp version_string(nil), do: nil
  defp version_string(value) when is_binary(value), do: value
  defp version_string(value) when is_integer(value), do: Integer.to_string(value)
  defp version_string(value) when is_float(value), do: Float.to_string(value)
  defp version_string(_value), do: nil

  @spec normalize_head(term()) :: String.t()
  defp normalize_head(head) when is_binary(head), do: head |> String.downcase() |> String.replace(" ", "_")
  defp normalize_head(_head), do: ""
end
