defmodule Harness.Projects.DispatchQA.Hooks do
  @moduledoc "Read-only inventory of configured hooks and installed plugins. Never installs or bypasses hooks."

  @doc "Captures user/project settings, installation metadata and the installed hook sources."
  @spec inventory(keyword()) :: map()
  def inventory(opts \\ []) do
    home = Keyword.get(opts, :home, System.user_home!())
    root = Keyword.get(opts, :project_root)
    installed_path = Path.join(home, ".claude/plugins/installed_plugins.json")
    installed = read_json(installed_path)

    config_paths =
      [
        Path.join(home, ".claude/settings.json"),
        Path.join(home, ".claude/settings.local.json"),
        Path.join(home, ".cursor/hooks.json"),
        "/etc/claude-code/managed-settings.json"
      ] ++ project_paths(root)

    plugins =
      case installed do
        {:ok, %{"plugins" => plugins}} ->
          Enum.flat_map(plugins, fn {name, entries} ->
            Enum.map(List.wrap(entries), fn entry ->
              path = entry["installPath"]

              sources =
                if is_binary(path) do
                  [Path.join(path, "hooks/hooks.json")] ++
                    Path.wildcard(Path.join(path, "hooks/**/*")) ++ Path.wildcard(Path.join(path, "scripts/**/*"))
                else
                  []
                end

              %{
                plugin: name,
                installation: entry,
                files: Enum.map(Enum.filter(Enum.uniq(sources), &File.regular?/1), &read_file/1)
              }
            end)
          end)

        _ ->
          []
      end

    settings = Enum.map(config_paths, &settings_file/1)

    %{
      settings: settings,
      configured_commands: Enum.flat_map(settings, &command_sources(&1, home, root)),
      enablement: "Raw scoped settings retained; shell expressions and plugin scope require operator review.",
      installation_registry: installed_path,
      installation_error:
        case installed do
          {:ok, _} -> nil
          {:error, reason} -> inspect(reason)
        end,
      installed_plugins: plugins,
      inherited_instructions:
        instruction_files(
          Enum.map(
            [
              ".claude/CLAUDE.md",
              ".claude/includes/verification-policy.md",
              ".claude/includes/critical-rules.md",
              ".claude/includes/harness-workflow.md"
            ],
            &Path.join(home, &1)
          ) ++ if(root, do: [Path.join(root, "CLAUDE.md")], else: []),
          home,
          MapSet.new()
        )
    }
  end

  @doc "Reads source bytes with their digest; absence and invalid text stay visible."
  @spec read_file(String.t()) :: map()
  def read_file(path) do
    case File.read(path) do
      {:ok, text} ->
        if String.valid?(text),
          do: %{path: path, sha256: :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower), content: text},
          else: %{path: path, error: "non_text"}

      {:error, reason} ->
        %{path: path, error: inspect(reason)}
    end
  end

  @spec command_sources(map(), String.t(), String.t() | nil) :: [map()]
  defp command_sources(settings, home, root) do
    settings
    |> Map.get(:settings, %{})
    |> commands()
    |> Enum.map(fn command ->
      tokens = command |> String.replace("${HOME}", home) |> String.replace("$HOME", home) |> OptionParser.split()
      paths = tokens |> Enum.map(&expand_path(&1, home, root || home)) |> Enum.filter(&File.regular?/1)

      %{
        configuration: settings.path,
        command: command,
        sources: Enum.map(Enum.uniq(paths), &read_file/1),
        resolution: "Literal file arguments only; no shell evaluation or recursive script execution."
      }
    end)
  end

  @spec commands(term()) :: [String.t()]
  defp commands(%{"command" => command}) when is_binary(command), do: [command]
  defp commands(map) when is_map(map), do: Enum.flat_map(Map.values(map), &commands/1)
  defp commands(list) when is_list(list), do: Enum.flat_map(list, &commands/1)
  defp commands(_), do: []

  @spec expand_path(String.t(), String.t(), String.t()) :: String.t()
  defp expand_path("~/" <> path, home, _base), do: Path.join(home, path)
  defp expand_path(path, _home, base), do: Path.expand(path, base)

  @spec instruction_files([String.t()], String.t(), MapSet.t()) :: [map()]
  defp instruction_files([], _home, _seen), do: []

  defp instruction_files([path | rest], home, seen) do
    path = Path.expand(path)

    if MapSet.member?(seen, path) do
      instruction_files(rest, home, seen)
    else
      file = read_file(path)
      references = Regex.scan(~r/(?:^|\s)@([^\s`]+\.md)/m, Map.get(file, :content, ""), capture: :all_but_first)
      paths = Enum.map(references, fn [reference] -> expand_path(reference, home, Path.dirname(path)) end)
      [file | instruction_files(paths ++ rest, home, MapSet.put(seen, path))]
    end
  end

  @spec settings_file(String.t()) :: map()
  defp settings_file(path) do
    case read_json(path) do
      {:ok, data} ->
        %{path: path, settings: Map.take(data, ["hooks", "enabledPlugins", "disabledPlugins", "disableAllHooks"])}

      {:error, reason} ->
        %{path: path, error: inspect(reason)}
    end
  end

  @spec read_json(String.t()) :: {:ok, map()} | {:error, term()}
  defp read_json(path) do
    with {:ok, content} <- File.read(path), do: Jason.decode(content)
  end

  @spec project_paths(String.t() | nil) :: [String.t()]
  defp project_paths(nil), do: []

  defp project_paths(root),
    do: Enum.map([".claude/settings.json", ".claude/settings.local.json", ".cursor/hooks.json"], &Path.join(root, &1))
end
