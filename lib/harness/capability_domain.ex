defmodule Harness.CapabilityDomain do
  @moduledoc """
  Advisory capability-domain vocabulary for KPI slicing and routing.

  Flat tag list — not hierarchical. Tags are declared on roadmap tasks and
  copied onto run records; they are metadata, not a contract (same posture as
  `Harness.AgentRegistry` availability).

  Curated tags use atoms; open-vocabulary tags stay strings so persistence does
  not depend on the writing node's atom table.
  """

  @typedoc "A declared capability domain tag."
  @type t :: atom() | String.t()

  @typedoc "Grouping bucket for records with no declared domains."
  @type bucket :: t() | :untagged

  @untagged :untagged

  # Elixir-stack starters; extend as new language stacks land (e.g. :rust).
  @elixir_domains [:otp, :genserver, :liveview, :phoenix, :ecto, :oban]

  # Cross-language / general domains beyond the Elixir starter set. Curated tags
  # restore as atoms; any other tag stays a string so an open vocabulary survives
  # persistence on nodes that never compiled the writing-side atom.
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
  def known?(domain) when is_binary(domain), do: domain in Enum.map(@domains, &Atom.to_string/1)
  def known?(_domain), do: false

  @doc """
  Normalizes declared domain tags for persistence and grouping.

  Curated strings become atoms; unknown atoms and strings become strings.
  Empty input stays empty — callers map that to `:untagged` at group time via
  `buckets/1`.
  """
  @spec normalize([term()]) :: [t()]
  def normalize(tags) when is_list(tags) do
    tags
    |> Enum.flat_map(&normalize_tag/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec normalize_tag(term()) :: [t()]
  defp normalize_tag(tag) when is_atom(tag) do
    if known?(tag), do: [tag], else: [Atom.to_string(tag)]
  end

  defp normalize_tag(tag) when is_binary(tag) do
    case Enum.find(@domains, &(Atom.to_string(&1) == tag)) do
      nil -> [tag]
      domain -> [domain]
    end
  end

  defp normalize_tag(_tag), do: []

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

  Accepts atom or string tags; rejects other values loudly.
  """
  @spec validate([term()]) :: {:ok, [t()]} | {:error, {:invalid_domain_tag, term()}}
  def validate(tags) when is_list(tags) do
    case Enum.find(tags, &(not (is_atom(&1) or is_binary(&1)))) do
      nil -> {:ok, normalize(tags)}
      bad -> {:error, {:invalid_domain_tag, bad}}
    end
  end
end
