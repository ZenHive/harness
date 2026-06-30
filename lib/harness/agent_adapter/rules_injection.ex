defmodule Harness.AgentAdapter.RulesInjection do
  @moduledoc """
  Per-adapter delivery of `Harness.AgentRules` at `build_command/1` time.

  - **Claude** — `--append-system-prompt-file` plus prompt-cache hint flag.
  - **Codex / Cursor** — ephemeral native rule files in the run worktree.
  - **Grok / Antigravity** — prompt preamble (no native system-prompt channel).
  """

  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentRules

  @doc """
  Flags for Claude's dedicated system-prompt append channel.
  """
  @spec claude_flags(Invocation.t()) :: {:ok, [String.t()]} | {:error, term()}
  def claude_flags(%Invocation{cwd: cwd} = invocation) do
    path = AgentRules.write_system_prompt_file!(cwd, render_opts(invocation))
    {:ok, ["--append-system-prompt-file", path, "--exclude-dynamic-system-prompt-sections"]}
  rescue
    error in File.Error -> {:error, {:rule_injection_failed, error.reason}}
  end

  @doc """
  Writes Codex's ephemeral `AGENTS.md` rules file into the worktree.
  """
  @spec install_codex_rules(Invocation.t()) :: :ok | {:error, term()}
  def install_codex_rules(%Invocation{cwd: cwd} = invocation) do
    AgentRules.install_codex_rules!(cwd, render_opts(invocation))
    :ok
  rescue
    error in File.Error -> {:error, {:rule_injection_failed, error.reason}}
  end

  @doc """
  Writes Cursor's ephemeral `.cursor/rules/` file into the worktree.
  """
  @spec install_cursor_rules(Invocation.t()) :: :ok | {:error, term()}
  def install_cursor_rules(%Invocation{cwd: cwd} = invocation) do
    AgentRules.install_cursor_rules!(cwd, render_opts(invocation))
    :ok
  rescue
    error in File.Error -> {:error, {:rule_injection_failed, error.reason}}
  end

  @doc """
  Prepends the canonical harness rules to a task prompt.
  """
  @spec prepend_prompt(String.t()) :: String.t()
  def prepend_prompt(prompt) when is_binary(prompt) do
    AgentRules.prompt_preamble() <> prompt
  end

  @doc """
  Prepends the canonical harness rules to a task prompt with language-aware sections.
  """
  @spec prepend_prompt(String.t(), Invocation.t()) :: String.t()
  def prepend_prompt(prompt, %Invocation{} = invocation) when is_binary(prompt) do
    AgentRules.prompt_preamble(render_opts(invocation)) <> prompt
  end

  @spec render_opts(Invocation.t()) :: [AgentRules.render_opt()]
  defp render_opts(%Invocation{languages: languages}) do
    if :elixir in languages do
      []
    else
      [exclude: [:verification_gates, :elixir]]
    end
  end
end
