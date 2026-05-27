defmodule Harness.Worktree.Isolation do
  @moduledoc """
  Guards harness runs against agents that write outside their isolated worktree.

  Adapters declare `worktree_isolation` in `Harness.AgentAdapter.Capabilities`.
  When `false`, `Harness.Run` fails before spawn. When `true` (the default),
  the run snapshots the main checkout's `git status --porcelain` before the
  agent runs and settles `:failed` / `:checkout_polluted` if non-allowlisted
  paths changed after.

  ## Pollution allowlist

  Orchestration overhead (Claude Code session state under `.claude/`, editor
  lockfiles, `.DS_Store`, etc.) can mutate the main checkout without the
  dispatched agent leaving its worktree. `check_pollution/3` filters porcelain
  lines whose paths match the allowlist before diffing.

  Defaults come from `default_pollution_allowlist/0`. Override globally via
  `config :harness, :run, pollution_allowlist: [...]`, per project on
  `%Harness.Project{}.pollution_allowlist`, or per run through
  `Harness.Run.Supervisor.start_run/4`'s `:pollution_allowlist` option.

  Patterns:

    * `"dir/"` — prefix match (e.g. `.claude/` ignores `.claude/scheduled_tasks.lock`)
    * `"*.swp"` — glob on the path basename
    * `"README.md"` — exact path match
  """

  alias Harness.AgentAdapter
  alias Harness.Git

  @default_pollution_allowlist [
    ".claude/",
    ".DS_Store",
    "*.swp",
    "*.swo",
    "*~",
    ".#*",
    "#*#"
  ]

  @doc """
  Default porcelain paths ignored by the checkout pollution diff.

  Covers Claude Code session state (`.claude/`), macOS metadata (`.DS_Store`),
  and common editor lock/temp files.
  """
  @spec default_pollution_allowlist() :: [String.t()]
  def default_pollution_allowlist, do: @default_pollution_allowlist

  @doc """
  Resolves the pollution allowlist from `opts`, application config, or defaults.

  Keyword `:pollution_allowlist` wins when present.
  """
  @spec pollution_allowlist(keyword()) :: [String.t()]
  def pollution_allowlist(opts \\ []) do
    Keyword.get(opts, :pollution_allowlist) ||
      :harness
      |> Application.get_env(:run, [])
      |> Keyword.get(:pollution_allowlist, @default_pollution_allowlist)
  end

  @doc """
  Returns `:ok` when `adapter` declares headless worktree isolation support.

  Otherwise returns `{:error, {:worktree_isolation_unsupported, adapter, message}}`
  so dispatch fails before the agent can pollute the canonical checkout.
  """
  @spec validate(module()) :: :ok | {:error, {:worktree_isolation_unsupported, module(), String.t()}}
  def validate(adapter) do
    if AgentAdapter.supports?(adapter, :worktree_isolation) do
      :ok
    else
      message =
        if function_exported?(adapter, :worktree_isolation_limitation, 0) do
          adapter.worktree_isolation_limitation()
        else
          "#{inspect(adapter)} declares worktree_isolation: false — see its @moduledoc"
        end

      {:error, {:worktree_isolation_unsupported, adapter, message}}
    end
  end

  @doc "Captures the main checkout's porcelain status for a later pollution check."
  @spec snapshot(String.t()) :: {:ok, String.t()} | {:error, Git.error()}
  def snapshot(repo) do
    Git.run(["status", "--porcelain"], repo)
  end

  @doc """
  Compares the checkout against `before_snapshot`.

  Porcelain lines whose paths match the resolved allowlist are ignored. Returns
  `:ok` when the filtered snapshots match or when no snapshot was taken;
  `{:error, {:checkout_polluted, diff}}` when non-allowlisted paths changed;
  or `{:error, {:checkout_pollution_check_failed, git_error}}` when the
  post-run snapshot itself failed (treated conservatively as failure — unknown
  state is not assumed clean).

  Pass `:pollution_allowlist` in `opts` to override patterns for this check.
  """
  @spec check_pollution(String.t(), String.t() | nil, keyword()) ::
          :ok
          | {:error, {:checkout_polluted, String.t()}}
          | {:error, {:checkout_pollution_check_failed, Git.error()}}
  def check_pollution(_repo, nil, _opts), do: :ok

  def check_pollution(repo, before, opts) when is_binary(before) do
    allowlist = pollution_allowlist(opts)

    case snapshot(repo) do
      {:ok, after_snapshot} ->
        if filtered_porcelain(before, allowlist) == filtered_porcelain(after_snapshot, allowlist) do
          :ok
        else
          {:error, {:checkout_polluted, filtered_porcelain(after_snapshot, allowlist)}}
        end

      {:error, reason} ->
        {:error, {:checkout_pollution_check_failed, reason}}
    end
  end

  @doc false
  @spec check_pollution(String.t(), String.t() | nil) ::
          :ok
          | {:error, {:checkout_polluted, String.t()}}
          | {:error, {:checkout_pollution_check_failed, Git.error()}}
  def check_pollution(_repo, nil), do: :ok

  def check_pollution(repo, before) when is_binary(before) do
    check_pollution(repo, before, [])
  end

  @spec filtered_porcelain(String.t(), [String.t()]) :: String.t()
  defp filtered_porcelain(porcelain, allowlist) do
    porcelain
    |> String.split("\n", trim: true)
    |> Enum.reject(&allowlisted_path?(&1, allowlist))
    |> Enum.sort()
    |> Enum.join("\n")
  end

  @spec allowlisted_path?(String.t(), [String.t()]) :: boolean()
  defp allowlisted_path?(line, allowlist) do
    line
    |> porcelain_path()
    |> allowlisted?(allowlist)
  end

  @spec porcelain_path(String.t()) :: String.t()
  defp porcelain_path(line) do
    case line do
      <<_status::binary-size(2), " ", rest::binary>> ->
        rest
        |> String.split(" -> ", parts: 2)
        |> List.last()

      _ ->
        line
    end
  end

  @spec allowlisted?(String.t(), [String.t()]) :: boolean()
  defp allowlisted?(path, allowlist) do
    Enum.any?(allowlist, &matches_pattern?(path, &1))
  end

  @spec matches_pattern?(String.t(), String.t()) :: boolean()
  defp matches_pattern?(path, pattern) do
    cond do
      String.ends_with?(pattern, "/") ->
        prefix = String.trim_trailing(pattern, "/")
        path == prefix or String.starts_with?(path, pattern)

      String.contains?(pattern, "*") ->
        glob_match?(Path.basename(path), pattern)

      true ->
        path == pattern
    end
  end

  @spec glob_match?(String.t(), String.t()) :: boolean()
  defp glob_match?(name, pattern) do
    pattern
    |> Regex.escape()
    |> String.replace("\\*", ".*")
    |> then(&("^" <> &1 <> "$"))
    |> Regex.compile!()
    |> Regex.match?(name)
  end
end
