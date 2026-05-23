defmodule Harness.AgentRules do
  @moduledoc """
  Canonical harness-owned rule set injected into agent invocations.

  - **One source** — `priv/agent_rules/canonical.md`, section-tagged for filtering.
  - **Curated subset** — methodology and harness operational instructions; verification
    numeric gates live in a tagged section excluded from injection (harness's
    verification runner enforces those, not agent prose).
  - **Ephemeral delivery** — adapters render from here into throwaway worktree files
    or prompt preambles; nothing is committed to target repos.
  """

  @rules_path Path.join([__DIR__, "..", "..", "priv", "agent_rules", "canonical.md"])
  @external_resource @rules_path
  @raw_rules File.read!(@rules_path)

  @default_exclude [:verification_gates]

  @system_prompt_rel ".harness/agent-rules.md"
  @cursor_rules_rel ".cursor/rules/harness-operational.mdc"
  @codex_agents_filename "AGENTS.md"

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
  Preamble prepended to the task prompt for agents without a native rule channel.
  """
  @spec prompt_preamble([render_opt()]) :: String.t()
  def prompt_preamble(opts \\ []) do
    rules = render(opts)

    """
    # Harness operational rules

    #{rules}

    ---

    """
  end

  @doc "Relative path (within `cwd`) of the Claude `--append-system-prompt-file` target."
  @spec system_prompt_rel_path() :: String.t()
  def system_prompt_rel_path, do: @system_prompt_rel

  @doc "Writes the rendered rules for Claude's system-prompt append channel."
  @spec write_system_prompt_file!(String.t(), [render_opt()]) :: String.t()
  def write_system_prompt_file!(cwd, opts \\ []) when is_binary(cwd) do
    root = worktree_root!(cwd)
    write_file!(root, @system_prompt_rel, render(opts))
    worktree_file!(root, @system_prompt_rel)
  end

  @doc "Installs harness rules for Codex via an ephemeral `AGENTS.md` in the worktree."
  @spec install_codex_rules!(String.t(), [render_opt()]) :: :ok
  def install_codex_rules!(cwd, opts \\ []) when is_binary(cwd) do
    root = worktree_root!(cwd)
    existing = read_optional(root, @codex_agents_filename)
    harness_block = codex_agents_block(render(opts))
    body = merge_agents_md(harness_block, existing)
    write_file!(root, @codex_agents_filename, body)
    :ok
  end

  @doc "Installs harness rules for Cursor via an ephemeral `.cursor/rules/` file."
  @spec install_cursor_rules!(String.t(), [render_opt()]) :: :ok
  def install_cursor_rules!(cwd, opts \\ []) when is_binary(cwd) do
    root = worktree_root!(cwd)
    write_file!(root, @cursor_rules_rel, cursor_rules_body(render(opts)))
    :ok
  end

  @doc "Section ids present in the canonical source."
  @spec section_ids() :: [section_id()]
  def section_ids do
    @raw_rules
    |> parse_sections()
    |> Enum.map(&elem(&1, 0))
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

  @spec codex_agents_block(String.t()) :: String.t()
  defp codex_agents_block(rules) do
    String.trim("""
    <!-- harness-injected: canonical agent rules — ephemeral, do not commit -->
    #{rules}
    """)
  end

  @spec cursor_rules_body(String.t()) :: String.t()
  defp cursor_rules_body(rules) do
    String.trim("""
    ---
    description: Harness operational rules injected at dispatch time
    alwaysApply: true
    ---

    #{rules}
    """)
  end

  @spec merge_agents_md(String.t(), String.t() | nil) :: String.t()
  defp merge_agents_md(harness_block, nil), do: harness_block

  defp merge_agents_md(harness_block, existing) do
    if String.contains?(existing, "harness-injected: canonical agent rules") do
      existing
    else
      harness_block <> "\n\n---\n\n" <> String.trim(existing)
    end
  end

  @spec read_optional(String.t(), String.t()) :: String.t() | nil
  # `rel` is one of this module's fixed harness-owned paths; `cwd` is the run
  # worktree root validated by `worktree_file!/2`.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_optional(cwd, rel) do
    path = worktree_file!(cwd, rel)

    case File.read(path) do
      {:ok, body} -> body
      {:error, :enoent} -> nil
      {:error, reason} -> raise File.Error, reason: reason, action: "read", path: path
    end
  end

  @spec write_file!(String.t(), String.t(), String.t()) :: :ok
  # `rel` is one of this module's fixed harness-owned paths; `cwd` is the run
  # worktree root validated by `worktree_file!/2`.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_file!(cwd, rel, body) do
    path = worktree_file!(cwd, rel)
    path |> Path.dirname() |> File.mkdir_p!()

    case File.write(path, body) do
      :ok -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "write", path: path
    end
  end

  @spec worktree_root!(String.t()) :: String.t()
  defp worktree_root!(cwd) do
    expanded = Path.expand(cwd)

    if !File.dir?(expanded) do
      raise ArgumentError, "worktree cwd is not a directory: #{cwd}"
    end

    expanded
  end

  @spec worktree_file!(String.t(), String.t()) :: String.t()
  defp worktree_file!(cwd, rel) do
    root = worktree_root!(cwd)
    path = Path.expand(Path.join(root, rel))

    if path == root or String.starts_with?(path, root <> "/") do
      path
    else
      raise ArgumentError, "path escapes worktree: #{rel}"
    end
  end
end
