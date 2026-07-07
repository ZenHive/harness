defmodule Harness.AgentAdapter.RulesInjection do
  @moduledoc """
  Per-adapter delivery of caller-supplied rule content at `build_command/1` time.

  - **Claude** — `--append-system-prompt-file` plus prompt-cache hint flag.
  - **Codex / Cursor** — ephemeral native rule files in the run worktree.
  - **Grok / Antigravity** — prompt preamble (no native system-prompt channel).
  """

  alias Harness.AgentAdapter.Invocation

  @system_prompt_rel ".harness/agent-rules.md"
  @cursor_rules_rel ".cursor/rules/harness-operational.mdc"
  @codex_agents_filename "AGENTS.md"
  @codex_agents_marker "<!-- harness-injected: canonical agent rules — ephemeral, do not commit -->"
  @codex_agents_separator "\n\n---\n\n"

  @doc """
  Flags for Claude's dedicated system-prompt append channel.
  """
  @spec claude_flags(Invocation.t()) :: {:ok, [String.t()]} | {:error, term()}
  def claude_flags(%Invocation{cwd: cwd, rule_content: rule_content}) do
    root = worktree_root!(cwd)
    path = write_file!(root, @system_prompt_rel, rule_content)
    {:ok, ["--append-system-prompt-file", path, "--exclude-dynamic-system-prompt-sections"]}
  rescue
    error in File.Error -> {:error, {:rule_injection_failed, error.reason}}
  end

  @doc """
  Writes Codex's ephemeral `AGENTS.md` rules file into the worktree.
  """
  @spec install_codex_rules(Invocation.t()) :: :ok | {:error, term()}
  def install_codex_rules(%Invocation{cwd: cwd, rule_content: rule_content}) do
    root = worktree_root!(cwd)
    existing = read_optional(root, @codex_agents_filename)
    body = rule_content |> codex_agents_block() |> merge_agents_md(existing)
    write_file!(root, @codex_agents_filename, body)
    :ok
  rescue
    error in File.Error -> {:error, {:rule_injection_failed, error.reason}}
  end

  @doc """
  Writes Cursor's ephemeral `.cursor/rules/` file into the worktree.
  """
  @spec install_cursor_rules(Invocation.t()) :: :ok | {:error, term()}
  def install_cursor_rules(%Invocation{cwd: cwd, rule_content: rule_content}) do
    root = worktree_root!(cwd)
    write_file!(root, @cursor_rules_rel, cursor_rules_body(rule_content))
    :ok
  rescue
    error in File.Error -> {:error, {:rule_injection_failed, error.reason}}
  end

  @doc """
  Prepends the caller-supplied rules to a task prompt.
  """
  @spec prepend_prompt(String.t(), String.t()) :: String.t()
  def prepend_prompt(prompt, rule_content) when is_binary(prompt) and is_binary(rule_content) do
    prompt_preamble(rule_content) <> prompt
  end

  @spec prompt_preamble(String.t()) :: String.t()
  defp prompt_preamble(rule_content) do
    """
    # Harness operational rules

    #{rule_content}

    ---

    """
  end

  @spec codex_agents_block(String.t()) :: String.t()
  defp codex_agents_block(rule_content) do
    String.trim("""
    #{@codex_agents_marker}
    #{rule_content}
    """)
  end

  @spec cursor_rules_body(String.t()) :: String.t()
  defp cursor_rules_body(rule_content) do
    String.trim("""
    ---
    description: Harness operational rules injected at dispatch time
    alwaysApply: true
    ---

    #{rule_content}
    """)
  end

  @spec merge_agents_md(String.t(), String.t() | nil) :: String.t()
  defp merge_agents_md(harness_block, nil), do: harness_block <> @codex_agents_separator

  defp merge_agents_md(harness_block, existing) do
    if String.contains?(existing, @codex_agents_marker) do
      existing
    else
      harness_block <> @codex_agents_separator <> existing
    end
  end

  @spec read_optional(String.t(), String.t()) :: String.t() | nil
  # `rel` is one of this module's fixed rule-delivery paths; `cwd` is validated
  # by `worktree_file!/2`.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_optional(cwd, rel) do
    path = worktree_file!(cwd, rel)

    case File.read(path) do
      {:ok, body} -> body
      {:error, :enoent} -> nil
      {:error, reason} -> raise File.Error, reason: reason, action: "read", path: path
    end
  end

  @spec write_file!(String.t(), String.t(), String.t()) :: String.t()
  # `rel` is one of this module's fixed rule-delivery paths; `cwd` is validated
  # by `worktree_file!/2`.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_file!(cwd, rel, body) do
    path = worktree_file!(cwd, rel)
    path |> Path.dirname() |> File.mkdir_p!()

    case File.write(path, body) do
      :ok -> path
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
