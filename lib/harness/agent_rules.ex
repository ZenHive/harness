defmodule Harness.AgentRules do
  @moduledoc """
  Canonical harness-owned rule set rendered for agent invocations.

  - **One source** — `priv/agent_rules/canonical.md`, section-tagged for filtering.
  - **Curated subset** — methodology and harness operational instructions; verification
    numeric gates live in a tagged section excluded from injection (harness's
    verification runner enforces those, not agent prose).
  - **Content only** — this module renders markdown. Delivery into worktree
    files / prompt preambles (and their cleanup) is owned by the agent-adapter
    subsystem (`Harness.AgentAdapter.RulesInjection`); callers pass the rendered
    string on `Harness.AgentAdapter.Invocation.rule_content`.
  """

  @rules_path Path.join([__DIR__, "..", "..", "priv", "agent_rules", "canonical.md"])
  @external_resource @rules_path
  @raw_rules File.read!(@rules_path)

  @default_exclude [:verification_gates]

  @section_body ~r/<!-- @section (\w+) -->\s*(.*?)(?=<!-- @section |\z)/s

  @type section_id :: atom()
  @type render_opt :: {:exclude, [section_id()]} | {:only, [section_id()]}

  @doc """
  Renders the canonical rule set as markdown.

  By default excludes `:verification_gates`. Pass `exclude: []` to include every
  section, or `only: [:operational, :methodology]` to render a subset.
  """
  @spec render([render_opt()]) :: String.t()
  def render(opts \\ []) do
    sections = parse_sections(@raw_rules)

    sections
    |> filter_sections(opts)
    |> Enum.map_join("\n\n", fn {_id, body} -> String.trim(body) end)
    |> String.trim()
  end

  @doc """
  Renders the canonical rule set for a project's languages.
  """
  @spec render_for_languages(nonempty_list(atom())) :: String.t()
  def render_for_languages(languages) when is_list(languages) do
    languages
    |> render_opts_for_languages()
    |> render()
  end

  @doc "Section ids present in the canonical source."
  @spec section_ids() :: [section_id()]
  def section_ids do
    @raw_rules
    |> parse_sections()
    |> Enum.map(&elem(&1, 0))
  end

  @spec render_opts_for_languages(nonempty_list(atom())) :: [render_opt()]
  defp render_opts_for_languages(languages) do
    if :elixir in languages do
      []
    else
      [exclude: [:verification_gates, :elixir]]
    end
  end

  @spec parse_sections(String.t()) :: [{section_id(), String.t()}]
  defp parse_sections(raw) do
    @section_body
    |> Regex.scan(raw, capture: :all_but_first)
    |> Enum.map(fn [id, body] -> {section_id(id), String.trim(body)} end)
  end

  @spec section_id(String.t()) :: section_id()
  defp section_id("operational"), do: :operational
  defp section_id("methodology"), do: :methodology
  defp section_id("elixir"), do: :elixir
  defp section_id("verification_gates"), do: :verification_gates
  defp section_id(other), do: raise(ArgumentError, "unknown agent rule section: #{other}")

  @spec filter_sections([{section_id(), String.t()}], [render_opt()]) :: [{section_id(), String.t()}]
  defp filter_sections(sections, opts) do
    excluded = Keyword.get(opts, :exclude, @default_exclude)
    only = Keyword.get(opts, :only, :all)

    sections
    |> Enum.reject(fn {id, _} -> id in excluded end)
    |> keep_only(only)
  end

  @spec keep_only([{section_id(), String.t()}], :all | [section_id()]) :: [{section_id(), String.t()}]
  defp keep_only(sections, :all), do: sections
  defp keep_only(sections, only), do: Enum.filter(sections, fn {id, _} -> id in only end)
end
