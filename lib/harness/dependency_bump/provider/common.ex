defmodule Harness.DependencyBump.Provider.Common do
  @moduledoc false

  alias Harness.DependencyBump.TaskSpec
  alias Harness.DepFreshness.Row

  @major_version_regex ~r/^\D*(\d+)/

  @doc false
  @spec specs(atom(), [Row.t()], keyword()) :: [TaskSpec.t()]
  def specs(language, rows, opts) when is_atom(language) and is_list(rows) and is_list(opts) do
    rows
    |> Enum.filter(&Row.outdated?/1)
    |> Enum.split_with(&major_bump?/1)
    |> build_specs(language, opts)
  end

  @doc false
  @spec facts_table([Row.t()]) :: String.t()
  def facts_table(rows) when is_list(rows) do
    Enum.join(
      [
        "| Dependency | Current | Latest | Constraint allowed |",
        "| --- | --- | --- | --- |" | Enum.map(rows, &fact_row/1)
      ],
      "\n"
    )
  end

  @doc false
  @spec dependency_names([Row.t()]) :: String.t()
  def dependency_names(rows) when is_list(rows) do
    Enum.map_join(rows, ", ", & &1.name)
  end

  @spec build_specs({[Row.t()], [Row.t()]}, atom(), keyword()) :: [TaskSpec.t()]
  defp build_specs({major, minor_patch}, language, opts) do
    minor_specs(minor_patch, language, opts) ++ major_specs(major, language, opts)
  end

  @spec minor_specs([Row.t()], atom(), keyword()) :: [TaskSpec.t()]
  defp minor_specs([], _language, _opts), do: []

  defp minor_specs(rows, language, opts) do
    [
      %TaskSpec{
        language: language,
        kind: :minor_patch,
        title: title(opts, "Update #{language_label(language)} minor and patch dependencies"),
        body: body(opts, rows, :minor_patch),
        acceptance_criteria: acceptance_criteria(opts, :minor_patch),
        files_to_modify: files(opts),
        check_command: check_command(opts),
        rows: rows
      }
    ]
  end

  @spec major_specs([Row.t()], atom(), keyword()) :: [TaskSpec.t()]
  defp major_specs(rows, language, opts) do
    Enum.map(rows, fn row ->
      %TaskSpec{
        language: language,
        kind: :major,
        title: title(opts, "Update #{language_label(language)} dependency #{row.name} to #{row.latest_version}"),
        body: body(opts, [row], :major),
        acceptance_criteria: acceptance_criteria(opts, :major),
        files_to_modify: files(opts),
        check_command: check_command(opts),
        rows: [row]
      }
    end)
  end

  @spec major_bump?(Row.t()) :: boolean()
  defp major_bump?(%Row{current_version: current, latest_version: latest}) do
    case {major(current), major(latest)} do
      {{:ok, current_major}, {:ok, latest_major}} -> current_major != latest_major
      _unknown -> true
    end
  end

  @spec major(String.t()) :: {:ok, non_neg_integer()} | :unknown
  defp major(version) when is_binary(version) do
    case Regex.run(@major_version_regex, version, capture: :all_but_first) do
      [major] -> {:ok, String.to_integer(major)}
      _none -> :unknown
    end
  end

  @spec title(keyword(), String.t()) :: String.t()
  defp title(opts, fallback), do: apply_template(opts, :title, [fallback])

  @spec body(keyword(), [Row.t()], TaskSpec.kind()) :: String.t()
  defp body(opts, rows, kind), do: apply_template(opts, :body, [rows, kind])

  @spec acceptance_criteria(keyword(), TaskSpec.kind()) :: [String.t()]
  defp acceptance_criteria(opts, kind), do: apply_template(opts, :acceptance_criteria, [kind])

  @spec files(keyword()) :: [String.t()]
  defp files(opts), do: Keyword.fetch!(opts, :files_to_modify)

  @spec check_command(keyword()) :: String.t()
  defp check_command(opts), do: Keyword.fetch!(opts, :check_command)

  @spec apply_template(keyword(), atom(), [term()]) :: term()
  defp apply_template(opts, key, args) do
    opts |> Keyword.fetch!(key) |> apply(args)
  end

  @spec fact_row(Row.t()) :: String.t()
  defp fact_row(%Row{} = row) do
    "| #{row.name} | #{row.current_version} | #{row.latest_version} | #{allowed(row.constraint_allowed)} |"
  end

  @spec allowed(boolean()) :: String.t()
  defp allowed(true), do: "yes"
  defp allowed(false), do: "no"

  @spec language_label(atom()) :: String.t()
  defp language_label(language), do: language |> Atom.to_string() |> String.capitalize()
end
