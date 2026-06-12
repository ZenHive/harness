defmodule Harness.Routing do
  @moduledoc """
  One-call routing fact brief for task-writer agents.

  This module joins existing read surfaces into JSON-safe maps so an
  orchestrator can choose assignee and model without reading `lib/`. It returns
  raw facts only: no recommendation, ranking, weighted score, or route verdict.
  """

  use Descripex, namespace: "/routing"

  alias Harness.Agents
  alias Harness.Config
  alias Harness.ModelAvailability
  alias Harness.ResultStore

  @zero_samples 0
  @all_fields [:agent, :model, :label, :roster, :availability, :kpi]

  @type metric :: %{value: term(), n: non_neg_integer()}
  @type field :: :agent | :model | :label | :roster | :availability | :kpi
  @type brief_opts :: [
          domains: [String.t() | atom()],
          agents: [String.t() | atom()],
          fields: [String.t() | atom()],
          include_all: boolean()
        ]
  @type routing_pair :: %{
          agent: String.t(),
          model: String.t(),
          label: String.t() | nil,
          roster: map(),
          availability: map(),
          kpi: map()
        }
  @type routing_brief :: %{
          domains: [String.t()],
          pairs: [routing_pair()]
        }

  api(
    :brief,
    "Return a thin routing index per dispatchable {agent, model}: roster, model availability, and KPI rollups. No best-pick, ranking, route, or fused score is computed.",
    params: [
      domains: [
        kind: :value,
        default: [],
        description:
          "Optional domain filter as strings, e.g. [\"otp\"]. Preserved on KPI cells so task-writers can see the requested routing scope.",
        schema: [String.t()]
      ],
      agents: [
        kind: :value,
        default: nil,
        description: ~s(Optional agent-name filter as strings, e.g. ["codex", "cursor"]. Unknown names add no pairs.),
        schema: [String.t()]
      ],
      fields: [
        kind: :value,
        default: nil,
        description:
          ~s(Optional pair-key projection as strings, e.g. ["agent", "model", "availability", "kpi"]. Unknown fields are ignored.),
        schema: [String.t()]
      ],
      include_all: [
        kind: :value,
        default: false,
        description:
          "When true, restores the verbose full catalog, including blocked, disabled, unavailable, and uninstalled pairs.",
        schema: boolean()
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %{domains: [String.t()], pairs: [%{agent, model, roster, availability, kpi}]}} or {:error, reason}. Every metric cell carries n."
    }
  )

  @spec brief() :: {:ok, routing_brief()} | {:error, term()}
  @spec brief(brief_opts() | [String.t() | atom()] | map() | nil) :: {:ok, routing_brief()} | {:error, term()}
  @spec brief(term(), term()) :: {:ok, routing_brief()} | {:error, term()}
  @spec brief(term(), term(), term()) :: {:ok, routing_brief()} | {:error, term()}
  @spec brief(term(), term(), term(), boolean()) :: {:ok, routing_brief()} | {:error, term()}
  def brief(domains \\ [], agents \\ nil, fields \\ nil, include_all \\ false) do
    opts = normalize_call(domains, agents, fields, include_all)
    opts = normalize_opts(opts)

    with {:ok, kpi} <- ResultStore.aggregate_by_agent(),
         {:ok, %{blocks: blocks}} <- ModelAvailability.list_blocks() do
      roster = Agents.list()
      blocks = block_index(blocks)

      pairs =
        roster
        |> filter_agents(opts.agents)
        |> Enum.flat_map(&agent_pairs(&1, opts, kpi, blocks))
        |> Enum.sort_by(&{&1.agent, &1.model})
        |> project_pairs(opts.fields)

      {:ok, %{domains: opts.domains, pairs: pairs}}
    end
  end

  @spec agent_pairs(map(), map(), map(), map()) :: [routing_pair()]
  defp agent_pairs(roster, opts, kpi, blocks) do
    agent = roster.agent

    case agent_atom(agent) do
      nil ->
        []

      agent_atom ->
        roster_facts = roster_facts(roster)

        if opts.include_all or dispatchable_roster?(roster_facts) do
          agent_atom
          |> availability_entries(agent, blocks)
          |> filter_availability(opts.include_all)
          |> Enum.map(&routing_pair(agent, &1, roster_facts, Map.get(kpi, agent_atom), opts.domains))
        else
          []
        end
    end
  end

  @spec routing_pair(String.t(), map(), map(), map() | nil, [String.t()]) :: routing_pair()
  defp routing_pair(agent, entry, roster_facts, kpi, domains) do
    %{
      agent: agent,
      model: entry.model,
      label: entry.label,
      roster: roster_facts,
      availability: Map.delete(entry, :label),
      kpi: kpi_cell(kpi, domains)
    }
  end

  @spec dispatchable_roster?(map()) :: boolean()
  defp dispatchable_roster?(roster) do
    roster.installed and roster.enabled and roster.available
  end

  @spec filter_availability([map()], boolean()) :: [map()]
  defp filter_availability(entries, true), do: entries
  defp filter_availability(entries, false), do: Enum.filter(entries, & &1.available)

  @spec agent_atom(String.t()) :: atom() | nil
  defp agent_atom(agent), do: Enum.find(Config.dispatch_agents(), &(Atom.to_string(&1) == agent))

  @spec availability_entries(atom(), String.t(), map()) :: [map()]
  defp availability_entries(agent, agent_name, blocks) do
    catalog = catalog(agent)
    available = available_model_index(agent_name)
    blocked_ids = blocked_model_ids(agent_name, blocks)

    (Enum.map(catalog, & &1.id) ++ blocked_ids)
    |> Enum.uniq()
    |> Enum.map(&availability_entry(agent_name, &1, catalog, available, blocks))
  end

  @spec availability_entry(String.t(), String.t(), [map()], map(), map()) :: map()
  defp availability_entry(agent, model, catalog, available, blocks) do
    block = Map.get(blocks, {agent, model}) || Map.get(blocks, {agent, "all"})
    catalog_entry = Enum.find(catalog, &(&1.id == model))

    %{
      model: model,
      label: label(catalog_entry, model),
      available: is_nil(block) and Map.has_key?(available, model),
      blocked: not is_nil(block),
      reason: block && block.reason,
      source: block && block.source,
      until: block && block.until
    }
  end

  @spec catalog(atom()) :: [map()]
  defp catalog(agent) do
    case ModelAvailability.catalog(agent) do
      {:ok, models} -> models
      {:error, :catalog_unavailable} -> []
    end
  end

  @spec available_model_index(String.t()) :: map()
  defp available_model_index(agent) do
    case ModelAvailability.list_available_models(agent) do
      {:ok, %{models: models}} -> Map.new(models, &{&1.id, true})
      {:error, _reason} -> %{}
    end
  end

  @spec blocked_model_ids(String.t(), map()) :: [String.t()]
  defp blocked_model_ids(agent, blocks) do
    blocks
    |> Map.keys()
    |> Enum.flat_map(fn
      {^agent, "all"} -> []
      {^agent, model} -> [model]
      _other -> []
    end)
  end

  @spec kpi_cell(map() | nil, [String.t()]) :: map()
  defp kpi_cell(nil, domains) do
    %{
      scope: "agent_all_domains",
      domains: domains,
      n: @zero_samples,
      measured: false,
      explore_candidate: true,
      success_rate: metric(nil, @zero_samples),
      first_attempt_pass: metric(nil, @zero_samples),
      duration_p90: metric(nil, @zero_samples),
      cost_to_approved: metric(nil, @zero_samples)
    }
  end

  defp kpi_cell(kpi, domains) do
    n = kpi.run_count

    %{
      scope: "agent_all_domains",
      domains: domains,
      n: n,
      measured: true,
      explore_candidate: false,
      reviewer_flaked: kpi.reviewer_flaked,
      success_rate: metric(kpi.success_rate, n),
      first_attempt_pass: metric(kpi.first_attempt_pass_rate, n),
      duration_p90: metric(kpi.duration_ms.p90, n),
      cost_to_approved: metric(kpi.cost_to_green, n)
    }
  end

  @spec roster_facts(map()) :: map()
  defp roster_facts(roster) do
    Map.take(roster, [
      :installed,
      :available,
      :enabled,
      :reviewer_eligible,
      :dispatchable_as_reviewer,
      :capabilities,
      :cost_tier,
      :model,
      :reviewer_model,
      :unavailable_reason
    ])
  end

  @spec block_index([map()]) :: map()
  defp block_index(blocks) do
    Map.new(blocks, fn block -> {{block.agent, block.model}, block} end)
  end

  @spec normalize_call(term(), term(), term(), term()) :: term()
  defp normalize_call(opts, nil, nil, false) when is_map(opts), do: opts
  defp normalize_call(opts, nil, nil, false) when is_list(opts) and opts != [] and is_tuple(hd(opts)), do: opts

  defp normalize_call(domains, agents, fields, include_all) do
    [domains: domains, agents: agents, fields: fields, include_all: include_all]
  end

  @spec normalize_opts(brief_opts() | [String.t() | atom()] | map()) :: map()
  defp normalize_opts(opts) when is_map(opts) do
    opts
    |> Keyword.new(fn {key, value} -> {normalize_option_key(key), value} end)
    |> normalize_opts()
  end

  defp normalize_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      %{
        domains: normalize_domains(Keyword.get(opts, :domains, [])),
        agents: normalize_agents(Keyword.get(opts, :agents)),
        fields: normalize_fields(Keyword.fetch(opts, :fields)),
        include_all: Keyword.get(opts, :include_all, false) == true
      }
    else
      %{
        domains: normalize_domains(opts),
        agents: nil,
        fields: nil,
        include_all: false
      }
    end
  end

  @spec normalize_option_key(String.t() | atom()) :: atom()
  defp normalize_option_key(key) when is_atom(key), do: key

  defp normalize_option_key(key) when is_binary(key) do
    case key do
      "domains" -> :domains
      "agents" -> :agents
      "fields" -> :fields
      "include_all" -> :include_all
      _unknown -> :unknown
    end
  end

  @spec filter_agents([map()], MapSet.t(String.t()) | nil) :: [map()]
  defp filter_agents(roster, nil), do: roster
  defp filter_agents(roster, agents), do: Enum.filter(roster, &MapSet.member?(agents, &1.agent))

  @spec normalize_agents([String.t() | atom()] | nil) :: MapSet.t(String.t()) | nil
  defp normalize_agents(nil), do: nil
  defp normalize_agents([]), do: nil
  defp normalize_agents(agents) when is_list(agents), do: MapSet.new(agents, &domain_name/1)

  @spec normalize_fields(:error | {:ok, [String.t() | atom()] | nil}) :: MapSet.t(field()) | nil
  defp normalize_fields(:error), do: nil
  defp normalize_fields({:ok, nil}), do: nil

  defp normalize_fields({:ok, fields}) when is_list(fields) do
    fields
    |> Enum.flat_map(&known_field/1)
    |> MapSet.new()
  end

  @spec known_field(String.t() | atom()) :: [field()]
  defp known_field(field) when field in @all_fields, do: [field]

  defp known_field(field) when is_binary(field) do
    Enum.filter(@all_fields, &(Atom.to_string(&1) == field))
  end

  defp known_field(_field), do: []

  @spec project_pairs([routing_pair()], MapSet.t(field()) | nil) :: [map()]
  defp project_pairs(pairs, nil), do: pairs

  defp project_pairs(pairs, fields) do
    Enum.map(pairs, &Map.take(&1, MapSet.to_list(fields)))
  end

  @spec normalize_domains([String.t() | atom()] | nil) :: [String.t()]
  defp normalize_domains(nil), do: []
  defp normalize_domains(domains) when is_list(domains), do: domains |> Enum.map(&domain_name/1) |> Enum.uniq()

  @spec domain_name(String.t() | atom()) :: String.t()
  defp domain_name(domain) when is_binary(domain), do: domain
  defp domain_name(domain) when is_atom(domain), do: Atom.to_string(domain)

  @spec metric(term(), non_neg_integer()) :: metric()
  defp metric(value, n), do: %{value: value, n: n}

  @spec label(map() | nil, String.t()) :: String.t()
  defp label(nil, model), do: model
  defp label(entry, _model), do: entry.label
end
