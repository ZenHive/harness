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
  alias Harness.ToolingBaseline.Provider
  alias Harness.ToolingBaseline.Snapshot
  alias Harness.ToolingBaseline.TaskSpec

  @check_command "mix compile --warnings-as-errors && mix ci"
  @files_to_modify ["mix.exs", "mix.lock", ".credo.exs", ".reach.exs", ".formatter.exs"]

  @impl Provider
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

  @impl Provider
  @spec build_task_spec(Project.t(), Snapshot.t(), keyword()) :: TaskSpec.t() | nil
  def build_task_spec(%Project{} = project, %Snapshot{} = snapshot, opts) when is_list(opts) do
    missing = missing_items(snapshot.items)

    if missing == [] do
      nil
    else
      skipped_languages = Keyword.get(opts, :skipped_languages, [])

      %TaskSpec{
        language: :elixir,
        kind: :tooling_baseline,
        title: "Bring #{project.name} Elixir tooling to baseline",
        body: body(project, missing, skipped_languages),
        acceptance_criteria: acceptance_criteria(),
        files_to_modify: @files_to_modify,
        check_command: @check_command,
        items: missing,
        skipped_languages: skipped_languages
      }
    end
  end

  @spec ensure_mix_exs(String.t()) :: :ok | {:skipped, :missing_mix_exs}
  defp ensure_mix_exs(path) do
    if File.regular?(path), do: :ok, else: {:skipped, :missing_mix_exs}
  end

  @spec missing_items([Item.t()]) :: [Item.t()]
  defp missing_items(items) do
    Enum.filter(items, fn item ->
      item.status == :missing and item.category in [:dep, :alias, :config_file]
    end)
  end

  @spec body(Project.t(), [Item.t()], [TaskSpec.skipped_language()]) :: String.t()
  defp body(%Project{} = project, missing, skipped_languages) do
    """
    Bring the Elixir project `#{project.name}` to the harness tooling baseline.

    Ground-truth tooling baseline drift facts:

    #{facts_table(missing)}

    These facts come from the stored tooling-baseline conformance scan. Treat them as ground truth for what is missing; do not replace them with guesses from docs or memory.

    Add the missing baseline tooling through the normal project code changes. Prefer `mix igniter.install vibe_kit` where applicable, then layer the elixir-setup extras that vibe_kit does not install. Make sure the committed surface includes the missing deps, the `ci` and `precommit` Mix aliases, and the `.credo.exs`, `.reach.exs`, and `.formatter.exs` config files named in the table.

    Reviewer check command for this tooling-baseline task: `#{@check_command}`. The reviewer runs it after the implementation; harness does not install deps, build, compile, or verify the project itself.

    #{skipped_languages_section(skipped_languages)}
    """
  end

  @spec facts_table([Item.t()]) :: String.t()
  defp facts_table(items) do
    Enum.join(
      [
        "| Category | Missing item | Fact id |",
        "| --- | --- | --- |" | Enum.map(items, &fact_row/1)
      ],
      "\n"
    )
  end

  @spec fact_row(Item.t()) :: String.t()
  defp fact_row(%Item{} = item) do
    "| #{item.category} | #{item.label} | #{item.id} |"
  end

  @spec skipped_languages_section([TaskSpec.skipped_language()]) :: String.t()
  defp skipped_languages_section([]), do: "No project languages were skipped by the baseline provider resolver."

  defp skipped_languages_section(skipped_languages) do
    """
    Skipped project languages with no tooling-baseline provider:

    #{skipped_languages_table(skipped_languages)}
    """
  end

  @spec skipped_languages_table([TaskSpec.skipped_language()]) :: String.t()
  defp skipped_languages_table(skipped_languages) do
    Enum.join(
      [
        "| Language | Reason |",
        "| --- | --- |" | Enum.map(skipped_languages, &skipped_language_row/1)
      ],
      "\n"
    )
  end

  @spec skipped_language_row(TaskSpec.skipped_language()) :: String.t()
  defp skipped_language_row(%{language: language, reason: reason}) do
    "| #{language} | #{inspect(reason)} |"
  end

  @spec acceptance_criteria() :: [String.t()]
  defp acceptance_criteria do
    [
      "Every missing Elixir tooling-baseline fact in the prompt is addressed in the committed project surface.",
      "The vibe_kit installer is preferred where it applies, with remaining elixir-setup extras layered afterward.",
      "The ci and precommit aliases plus .credo.exs, .reach.exs, and .formatter.exs are wired to the baseline.",
      "The reviewer runs the listed compile + gate command and records the result; harness performs no local verification."
    ]
  end

  @spec build_items(Manifest.t(), map(), String.t(), map()) :: [Item.t()]
  defp build_items(manifest, surface, repo_path, overrides) do
    dep_items(manifest.deps, surface.deps, overrides) ++
      alias_items(manifest.aliases, surface.aliases, overrides) ++
      config_items(manifest.config_files, repo_path, overrides)
  end

  @spec dep_items([String.t()], MapSet.t(String.t()), map()) :: [Item.t()]
  defp dep_items(required, present, overrides) do
    Enum.map(required, fn dep ->
      id = "dep:#{dep}"

      %Item{
        id: id,
        label: dep,
        category: :dep,
        status: item_status(id, MapSet.member?(present, dep), overrides),
        override_reason: Map.get(overrides, id)
      }
    end)
  end

  @spec alias_items([String.t()], MapSet.t(String.t()), map()) :: [Item.t()]
  defp alias_items(required, present, overrides) do
    Enum.map(required, fn alias_name ->
      id = "alias:#{alias_name}"

      %Item{
        id: id,
        label: alias_name,
        category: :alias,
        status: item_status(id, MapSet.member?(present, alias_name), overrides),
        override_reason: Map.get(overrides, id)
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
        override_reason: Map.get(overrides, id)
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
    Map.has_key?(overrides, id)
  end
end
