defmodule Harness.ToolingBaseline.Provider.Elixir do
  @moduledoc """
  Elixir tooling-baseline scan over committed mix.exs and config files.

  Compares the project surface against the harness-shipped vibe_kit/elixir-setup
  manifest — presence only, not dep version currency (Task 331 owns that).
  """

  @behaviour Harness.ToolingBaseline.Provider

  alias Harness.Project
  alias Harness.ToolingBaseline.Item
  alias Harness.ToolingBaseline.Manifest
  alias Harness.ToolingBaseline.MixProjectReader
  alias Harness.ToolingBaseline.Snapshot

  @impl Harness.ToolingBaseline.Provider
  @spec scan(Project.t(), String.t(), keyword()) ::
          {:ok, Snapshot.t()} | {:error, term()} | {:skipped, term()}
  def scan(project, repo_path, _opts) when is_binary(repo_path) do
    mix_path = Path.join(repo_path, "mix.exs")

    with :ok <- ensure_mix_exs(mix_path),
         {:ok, manifest} <- Manifest.elixir(),
         {:ok, surface} <- MixProjectReader.read(mix_path) do
      items = build_items(manifest, surface, repo_path, project.tooling_baseline_overrides || %{})
      {:ok, Snapshot.build(items, manifest.advisory)}
    end
  end

  @spec ensure_mix_exs(String.t()) :: :ok | {:skipped, :missing_mix_exs}
  defp ensure_mix_exs(path) do
    if File.regular?(path), do: :ok, else: {:skipped, :missing_mix_exs}
  end

  @spec build_items(Manifest.t(), map(), String.t(), map()) :: [Item.t()]
  defp build_items(manifest, surface, repo_path, overrides) do
    dep_items(manifest.deps, surface.deps, overrides) ++
      alias_items(manifest.aliases, surface.aliases, overrides) ++
      config_items(manifest.config_files, repo_path, overrides)
  end

  @spec dep_items([String.t()], MapSet.t(atom()), map()) :: [Item.t()]
  defp dep_items(required, present, overrides) do
    Enum.map(required, fn dep ->
      id = "dep:#{dep}"

      %Item{
        id: id,
        label: dep,
        category: :dep,
        status: item_status(id, MapSet.member?(present, String.to_atom(dep)), overrides),
        override_reason: Map.get(overrides, id) || Map.get(overrides, String.to_atom(id))
      }
    end)
  end

  @spec alias_items([String.t()], MapSet.t(atom()), map()) :: [Item.t()]
  defp alias_items(required, present, overrides) do
    Enum.map(required, fn alias_name ->
      id = "alias:#{alias_name}"

      %Item{
        id: id,
        label: alias_name,
        category: :alias,
        status: item_status(id, MapSet.member?(present, String.to_atom(alias_name)), overrides),
        override_reason: Map.get(overrides, id) || Map.get(overrides, String.to_atom(id))
      }
    end)
  end

  @spec config_items([String.t()], String.t(), map()) :: [Item.t()]
  defp config_items(required, repo_path, overrides) do
    Enum.map(required, fn filename ->
      id = "config:#{filename}"
      present? = File.regular?(Path.join(repo_path, filename))

      %Item{
        id: id,
        label: filename,
        category: :config_file,
        status: item_status(id, present?, overrides),
        override_reason: Map.get(overrides, id) || Map.get(overrides, String.to_atom(id))
      }
    end)
  end

  @spec item_status(String.t(), boolean(), map()) :: Item.status()
  defp item_status(id, present?, overrides) do
    cond do
      override?(id, overrides) -> :overridden
      present? -> :present
      true -> :missing
    end
  end

  @spec override?(String.t(), map()) :: boolean()
  defp override?(id, overrides) do
    Map.has_key?(overrides, id) or Map.has_key?(overrides, String.to_atom(id))
  end
end
