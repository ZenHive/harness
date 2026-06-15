defmodule Harness.CapabilityDomain do
  @moduledoc """
  Advisory capability-domain vocabulary for KPI slicing and routing.

  Flat atom list — not hierarchical. Tags are declared on roadmap tasks and
  copied onto run records; they are metadata, not a contract (same posture as
  `Harness.AgentRegistry` availability).

  Unknown atoms are kept at normalize time so new stacks (e.g. `:rust`) land
  without a code change; `@domains/0` is the curated starter set only.
  """

  @typedoc "A declared capability domain tag."
  @type t :: atom()

  @typedoc "Grouping bucket for records with no declared domains."
  @type bucket :: t() | :untagged

  @untagged :untagged

  # Elixir-stack starters; extend as new language stacks land (e.g. :rust).
  @elixir_domains [:otp, :genserver, :liveview, :phoenix, :ecto, :oban]

  # Cross-language / general domains beyond the Elixir starter set. Each atom must
  # be pre-registered here so `String.to_existing_atom/1` (the rmap-`domains` →
  # atom path in `Harness.Roadmap.task_domains/1`) resolves it instead of dropping
  # it to the `:untagged` bucket — that is how JS/TS tasks get domain-sliced KPIs.
  @general_domains [:rust, :elixir, :javascript, :typescript]

  @domains (@elixir_domains ++ @general_domains) |> Enum.uniq() |> Enum.sort()

  @doc "Returns the canonical domain vocabulary (sorted, deduped)."
  @spec domains() :: [t()]
  def domains, do: @domains

  @doc "Grouping bucket for records that carry no domain tags."
  @spec untagged() :: :untagged
  def untagged, do: @untagged

  @doc "Whether `domain` is in the canonical vocabulary."
  @spec known?(t()) :: boolean()
  def known?(domain) when is_atom(domain), do: domain in @domains

  @doc """
  Normalizes declared domain tags for persistence and grouping.

  Drops non-atoms, dedupes, sorts. Unknown atoms are kept. An empty input
  stays empty — callers map that to `:untagged` at group time via `buckets/1`.
  """
  @spec normalize([term()]) :: [t()]
  def normalize(tags) when is_list(tags) do
    tags
    |> Enum.filter(&is_atom/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Domain bucket keys for one record's tags.

  Returns `[:untagged]` when tags are empty; otherwise the normalized tags.
  """
  @spec buckets([t()]) :: [bucket()]
  def buckets(tags) when is_list(tags) do
    case normalize(tags) do
      [] -> [@untagged]
      normalized -> normalized
    end
  end

  @doc """
  Validates domain tags from external input (e.g. a TOML corpus item).

  Accepts atoms only; rejects non-atoms loudly. Unknown atoms pass through.
  """
  @spec validate([term()]) :: {:ok, [t()]} | {:error, {:invalid_domain_tag, term()}}
  def validate(tags) when is_list(tags) do
    case Enum.find(tags, &(not is_atom(&1))) do
      nil -> {:ok, normalize(tags)}
      bad -> {:error, {:invalid_domain_tag, bad}}
    end
  end
end
