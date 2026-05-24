defmodule Harness.Worktree.Isolation do
  @moduledoc """
  Guards harness runs against agents that write outside their isolated worktree.

  Adapters declare `worktree_isolation` in `Harness.AgentAdapter.Capabilities`.
  When `false`, `Harness.Run` fails before spawn. When `true` (the default),
  the run snapshots the main checkout's `git status --porcelain` before the
  agent runs and settles `:failed` / `:checkout_polluted` if it changed after.
  """

  alias Harness.AgentAdapter
  alias Harness.Git

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

  Returns `:ok` when unchanged or when no snapshot was taken; otherwise
  `{:error, {:checkout_polluted, diff}}`.
  """
  @spec check_pollution(String.t(), String.t() | nil) :: :ok | {:error, {:checkout_polluted, String.t()}}
  def check_pollution(_repo, nil), do: :ok

  def check_pollution(repo, before) when is_binary(before) do
    case snapshot(repo) do
      {:ok, ^before} -> :ok
      {:ok, after_snapshot} -> {:error, {:checkout_polluted, after_snapshot}}
      {:error, reason} -> {:error, {:checkout_pollution_check_failed, reason}}
    end
  end
end
