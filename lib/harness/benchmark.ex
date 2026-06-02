defmodule Harness.Benchmark do
  @moduledoc """
  Helpers for turning fixed benchmark corpus items into dispatchable roadmap items.
  """

  alias Harness.Benchmark.Item
  alias Harness.Roadmap.Item, as: RoadmapItem

  @doc """
  Builds a `%Harness.Roadmap.Item{}` for one agent from a benchmark corpus item.

  The prompt is deterministic from the corpus contract (intent + acceptance
  criteria) so every adapter on a cell runs the same task text.
  """
  @spec as_roadmap_item(Item.t(), Harness.AgentRegistry.agent()) :: RoadmapItem.t()
  def as_roadmap_item(%Item{} = item, agent) when is_atom(agent) do
    %RoadmapItem{
      id: item.id,
      title: item.id,
      prompt: prompt(item),
      agent: agent,
      body: item.intent,
      acceptance_criteria: item.acceptance_criteria,
      domains: item.domains
    }
  end

  @spec prompt(Item.t()) :: String.t()
  defp prompt(%Item{} = item) do
    criteria = Enum.map_join(item.acceptance_criteria, "\n", &"- #{&1}")

    String.trim("""
    # Benchmark: #{item.id}

    #{item.intent}

    ## Acceptance criteria
    #{criteria}
    """)
  end
end
