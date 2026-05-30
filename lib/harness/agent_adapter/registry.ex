defmodule Harness.AgentAdapter.Registry do
  @moduledoc """
  Single source of truth mapping an adapter NAME (as an orchestrator passes it
  over a JSON boundary) to its `{adapter module, render agent}` pair.

  The render agent is what `rmap delegate` renders the prompt for; the adapter
  module is what actually executes. They diverge for the non-delegatable
  executors (grok/antigravity/pi), which render via `:claude` but run on their
  own module.

  A leaf module (no other Harness deps) so both `Harness.Dispatch` and the
  merge-train `Harness.Lander.Resilience` resolve adapters from one table
  without a dependency cycle.
  """

  alias Harness.AgentAdapter

  # Adapter name → {adapter module, render agent}.
  @adapters %{
    "claude" => {AgentAdapter.Claude, :claude},
    "codex" => {AgentAdapter.Codex, :codex},
    "cursor" => {AgentAdapter.Cursor, :cursor},
    "grok" => {AgentAdapter.Grok, :claude},
    "antigravity" => {AgentAdapter.Antigravity, :claude},
    "pi" => {AgentAdapter.Pi, :claude}
  }

  # The Oban fan-out path keys each enqueued job's adapter off the ingested
  # item's render agent, so only these three can be driven there; a
  # non-delegatable name would silently run claude.
  @delegatable_adapters ~w(claude codex cursor)

  @doc """
  Resolve an adapter name to its `{module, render_agent}` pair.

  ## Examples

      iex> Harness.AgentAdapter.Registry.resolve("claude")
      {:ok, {Harness.AgentAdapter.Claude, :claude}}

      iex> Harness.AgentAdapter.Registry.resolve("nope")
      {:error, {:unknown_adapter, "nope"}}
  """
  @spec resolve(String.t()) :: {:ok, {module(), atom()}} | {:error, {:unknown_adapter, String.t()}}
  def resolve(adapter) when is_binary(adapter) do
    case Map.fetch(@adapters, adapter) do
      {:ok, pair} -> {:ok, pair}
      :error -> {:error, {:unknown_adapter, adapter}}
    end
  end

  @doc """
  Whether `adapter` is one of the three delegatable executors (claude/codex/cursor).

  ## Examples

      iex> Harness.AgentAdapter.Registry.delegatable?("codex")
      true

      iex> Harness.AgentAdapter.Registry.delegatable?("grok")
      false
  """
  @spec delegatable?(String.t()) :: boolean()
  def delegatable?(adapter) when is_binary(adapter), do: adapter in @delegatable_adapters
end
