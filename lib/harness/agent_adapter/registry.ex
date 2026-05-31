defmodule Harness.AgentAdapter.Registry do
  @moduledoc """
  Single source of truth mapping an adapter NAME (as an orchestrator passes it
  over a JSON boundary) to its `{adapter module, render agent}` pair.

  The render agent is what `rmap delegate` renders the prompt for; the adapter
  module is what actually executes. As of rmap's widened `delegate --to` enum
  (claude/codex/cursor/grok/antigravity/pi/droid), every harness adapter renders
  natively — name and render agent coincide. `droid` is renderable by rmap but
  has no harness adapter, so it never appears here and resolves to
  `{:unknown_adapter, "droid"}`.

  A leaf module (no other Harness deps) so both `Harness.Dispatch` and the
  merge-train `Harness.Lander.Resilience` resolve adapters from one table
  without a dependency cycle.
  """

  alias Harness.AgentAdapter

  # Adapter name → {adapter module, render agent}. rmap renders a native prompt
  # for every name here, so render agent == name throughout.
  @adapters %{
    "claude" => {AgentAdapter.Claude, :claude},
    "codex" => {AgentAdapter.Codex, :codex},
    "cursor" => {AgentAdapter.Cursor, :cursor},
    "grok" => {AgentAdapter.Grok, :grok},
    "antigravity" => {AgentAdapter.Antigravity, :antigravity},
    "pi" => {AgentAdapter.Pi, :pi}
  }

  # The Oban fan-out path keys each enqueued job's adapter off the ingested
  # item's render agent. Since rmap now renders natively for all six, every
  # harness adapter is delegatable there.
  @delegatable_adapters ~w(claude codex cursor grok antigravity pi)

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
  Whether `adapter` is a delegatable executor — i.e. rmap renders a native
  prompt for it and harness has an adapter to run it.

  True for all six harness adapters (claude/codex/cursor/grok/antigravity/pi).
  False for a name harness can't execute, such as `droid` (renderable by rmap,
  no harness adapter).

  ## Examples

      iex> Harness.AgentAdapter.Registry.delegatable?("grok")
      true

      iex> Harness.AgentAdapter.Registry.delegatable?("droid")
      false
  """
  @spec delegatable?(String.t()) :: boolean()
  def delegatable?(adapter) when is_binary(adapter), do: adapter in @delegatable_adapters
end
