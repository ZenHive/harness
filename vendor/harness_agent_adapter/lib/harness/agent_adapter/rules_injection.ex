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
  @cursor_rules_backup_rel ".harness/cursor-rules-operational.mdc.orig"
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
    backup_preexisting_cursor_rules(root)
    write_file!(root, @cursor_rules_rel, cursor_rules_body(rule_content))
    :ok
  rescue
    error in File.Error -> {:error, {:rule_injection_failed, error.reason}}
  end

  @spec backup_preexisting_cursor_rules(String.t()) :: :ok
  # A project may already own a file at the Cursor rules path (harness's own
  # rules file has been committed into target repos by accident). Cleanup
  # removes what harness wrote, so without this the project's file is destroyed
  # by every run and shows up as a spurious deletion in the delivery diff.
  # Preserve it here; `restore_cursor_rules/1` puts it back. The backup is taken
  # once per worktree: the reviewer installs into the same worktree after the
  # implementer, and a second backup would capture the injected body.
  defp backup_preexisting_cursor_rules(root) do
    existing = read_optional(root, @cursor_rules_rel)
    backup = read_optional(root, @cursor_rules_backup_rel)

    if is_binary(existing) and is_nil(backup) do
      write_file!(root, @cursor_rules_backup_rel, existing)
    end

    :ok
  end

  @doc """
  Prepends the caller-supplied rules to a task prompt.
  """
  @spec prepend_prompt(String.t(), String.t()) :: String.t()
  def prepend_prompt(prompt, rule_content) when is_binary(prompt) and is_binary(rule_content) do
    prompt_preamble(rule_content) <> prompt
  end

  @doc """
  Removes previously injected rule files from a run worktree.

  Callers (worktree reuse / pre-delivery reset) invoke this so a stale
  injection from an earlier attempt never leaks into the next agent. The
  Claude system-prompt file lives at a fixed harness-owned path and is simply
  removed. The Cursor rules path may be owned by the project, so a file
  displaced at install time is restored rather than deleted. Codex's
  `AGENTS.md` may hold merged repo content after the injected block, so only
  the marker-prefixed harness block is stripped and any remainder is preserved.
  A marker-prefixed file with no separator is entirely harness-written and is
  removed.
  """
  @spec cleanup_injected_rules(String.t()) :: :ok | {:error, {:rule_cleanup_failed, String.t(), File.posix()}}
  def cleanup_injected_rules(cwd) when is_binary(cwd) do
    root = worktree_root!(cwd)

    with :ok <- remove_file(root, @system_prompt_rel),
         :ok <- restore_cursor_rules(root) do
      cleanup_codex_agents(root)
    end
  end

  @spec restore_cursor_rules(String.t()) ::
          :ok | {:error, {:rule_cleanup_failed, String.t(), File.posix()}}
  # Puts back the project-owned file `install_cursor_rules/1` displaced. With no
  # backup the injected file is harness's alone and is simply removed.
  # `@cursor_rules_backup_rel` is a fixed harness-owned path; `cwd` is validated
  # by `worktree_file!/2`.
  # sobelow_skip ["Traversal.FileModule"]
  defp restore_cursor_rules(root) do
    path = worktree_file!(root, @cursor_rules_backup_rel)

    case File.read(path) do
      {:ok, body} -> write_restored_cursor_rules(root, path, body)
      {:error, :enoent} -> remove_file(root, @cursor_rules_rel)
      {:error, reason} -> {:error, {:rule_cleanup_failed, path, reason}}
    end
  end

  @spec write_restored_cursor_rules(String.t(), String.t(), String.t()) ::
          :ok | {:error, {:rule_cleanup_failed, String.t(), File.posix()}}
  defp write_restored_cursor_rules(root, backup_path, body) do
    with :ok <- write_path(worktree_file!(root, @cursor_rules_rel), body) do
      remove_path(backup_path)
    end
  end

  @spec cleanup_codex_agents(String.t()) ::
          :ok | {:error, {:rule_cleanup_failed, String.t(), File.posix()}}
  # `@codex_agents_filename` is a fixed rule-delivery path; `cwd` is validated
  # by `worktree_file!/2`.
  # sobelow_skip ["Traversal.FileModule"]
  defp cleanup_codex_agents(cwd) do
    path = worktree_file!(cwd, @codex_agents_filename)

    case File.read(path) do
      {:ok, body} -> cleanup_codex_agents_body(path, body)
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:rule_cleanup_failed, path, reason}}
    end
  end

  @spec cleanup_codex_agents_body(String.t(), String.t()) ::
          :ok | {:error, {:rule_cleanup_failed, String.t(), File.posix()}}
  defp cleanup_codex_agents_body(path, body) do
    cond do
      not String.starts_with?(body, @codex_agents_marker) ->
        :ok

      String.contains?(body, @codex_agents_separator) ->
        [_harness_block, remainder] = String.split(body, @codex_agents_separator, parts: 2)

        remainder
        |> String.trim_leading()
        |> write_codex_agents_remainder(path)

      true ->
        # Marker-prefixed with no separator: the whole file is the injected block.
        remove_path(path)
    end
  end

  @spec write_codex_agents_remainder(String.t(), String.t()) ::
          :ok | {:error, {:rule_cleanup_failed, String.t(), File.posix()}}
  defp write_codex_agents_remainder("", path), do: remove_path(path)
  defp write_codex_agents_remainder(body, path), do: write_path(path, body)

  @spec remove_file(String.t(), String.t()) ::
          :ok | {:error, {:rule_cleanup_failed, String.t(), File.posix()}}
  defp remove_file(cwd, rel) do
    cwd
    |> worktree_file!(rel)
    |> remove_path()
  end

  @spec remove_path(String.t()) :: :ok | {:error, {:rule_cleanup_failed, String.t(), File.posix()}}
  # `path` is always constructed via `worktree_file!/2`, which validates the
  # path stays under the run worktree root.
  # sobelow_skip ["Traversal.FileModule"]
  defp remove_path(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:rule_cleanup_failed, path, reason}}
    end
  end

  @spec write_path(String.t(), String.t()) ::
          :ok | {:error, {:rule_cleanup_failed, String.t(), File.posix()}}
  # `path` is always constructed via `worktree_file!/2`, which validates the
  # path stays under the run worktree root.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_path(path, body) do
    case File.write(path, body) do
      :ok -> :ok
      {:error, reason} -> {:error, {:rule_cleanup_failed, path, reason}}
    end
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
