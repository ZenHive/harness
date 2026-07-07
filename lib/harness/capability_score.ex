defmodule Harness.CapabilityScore do
  @moduledoc """
  Per-facet routing oracle — scout AI competence assessment over grouped run facts.

  Raw run records carry reviewer-assigned `review_facets` (the routing KEY).
  Harness groups them mechanically, rolls per-agent facts via `Harness.AgentKPI`
  (pure counting — no weights), and hands that ledger to a scout AI. The scout
  writes which agent wins each task-kind on approve / first-try / quality / cost,
  with reasoning. `dispatch-recommend` matches an incoming task's facets against
  that artifact — never a recomputed composite scalar.

  Active routing never reads or writes legacy composite score cells.
  """

  alias Harness.AgentAdapter.Driver
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Outcome
  alias Harness.AgentKPI
  alias Harness.AgentRegistry
  alias Harness.AgentRules
  alias Harness.CapabilityScore.Recommendation
  alias Harness.Config
  alias Harness.Facet
  alias Harness.ResultStore
  alias Harness.Run.LogRecord

  @artifact_basename "facet-assessment.json"
  @artifact_rel ".harness/#{@artifact_basename}"
  @default_root "~/.harness"
  @default_adapter :codex
  @default_idle_timeout 120_000
  @default_total_timeout 300_000
  @known_agents [:claude, :codex, :cursor, :grok, :antigravity, :pi]
  @known_agent_names Map.new(@known_agents, &{Atom.to_string(&1), &1})

  defmodule Assessment do
    @moduledoc false

    @typedoc false
    @type t :: %__MODULE__{
            assessed_at: DateTime.t() | nil,
            record_count: non_neg_integer(),
            entries: [Harness.CapabilityScore.Entry.t()]
          }

    @enforce_keys [:assessed_at, :record_count, :entries]
    defstruct [:assessed_at, :record_count, entries: []]
  end

  defmodule Entry do
    @moduledoc false

    @typedoc false
    @type t :: %__MODULE__{
            facet: %{optional(String.t()) => term()},
            winner: atom(),
            reasoning: String.t(),
            by_agent: %{optional(atom()) => map()}
          }

    @enforce_keys [:facet, :winner, :reasoning, :by_agent]
    defstruct [:facet, :winner, :reasoning, :by_agent]
  end

  @typedoc "Parsed scout assessment artifact."
  @type assessment :: Assessment.t()

  @typedoc "One per-facet routing cell from the scout."
  @type entry :: Entry.t()

  @doc """
  Groups run records by reviewer-assigned `review_facets`.

  Empty or missing facets bucket under `%{}` (the unfaceted bucket). Keys within
  each facet map are normalized to strings for stable grouping.
  """
  @spec group_by_facet([LogRecord.t()]) :: %{String.t() => [LogRecord.t()]}
  def group_by_facet(records) when is_list(records) do
    records
    |> Enum.group_by(&facet_key(normalize_facet(&1.review_facets)))
    |> Map.new(fn {key, group} -> {key, group} end)
  end

  @doc """
  Rolls per-agent KPI facts for one facet group's records.

  Returns a map keyed by agent atom with `Harness.AgentKPI` ledger cells.
  """
  @spec facet_facts([LogRecord.t()]) :: %{optional(atom()) => AgentKPI.agent_kpi()}
  def facet_facts(records) when is_list(records) do
    AgentKPI.aggregate(records)
  end

  @doc "Builds facet-grouped fact ledgers from a record list — scout input, not a verdict."
  @spec build_scout_context([LogRecord.t()]) :: [map()]
  def build_scout_context(records) when is_list(records) do
    records
    |> group_by_facet()
    |> Enum.map(fn {_key, group} ->
      facet = normalize_facet(hd(group).review_facets)

      %{
        facet: facet,
        by_agent: facet_facts(group)
      }
    end)
    |> Enum.sort_by(&Jason.encode!(Map.get(&1, :facet, %{})))
  end

  @doc """
  Reads the persisted per-facet assessment artifact.

  Returns `:no_data` when no assessment has been written yet.
  """
  @spec read_assessment(keyword()) :: {:ok, assessment()} | :no_data | {:error, term()}
  # sobelow_skip ["Traversal.FileModule"]
  def read_assessment(opts \\ []) when is_list(opts) do
    path = assessment_path(opts)

    case File.read(path) do
      {:ok, body} -> decode_assessment(body)
      {:error, :enoent} -> :no_data
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Persists a parsed assessment artifact to the configured assessment path."
  @spec save_assessment(assessment(), keyword()) :: :ok | {:error, term()}
  # sobelow_skip ["Traversal.FileModule"]
  def save_assessment(%Assessment{} = assessment, opts \\ []) when is_list(opts) do
    path = assessment_path(opts)
    payload = encode_assessment(assessment)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, payload)
    end
  end

  @doc """
  Refreshes the per-facet assessment: group records, spawn the scout AI, persist.

  Injectable via `config :harness, :capability_scout` (`fun(context) ::
  {:ok, assessment} | {:error, term()}`) for tests.
  """
  @spec refresh(keyword()) :: {:ok, assessment()} | {:error, term()}
  def refresh(opts \\ []) when is_list(opts) do
    store = Keyword.get(opts, :result_store, ResultStore.configured())

    with {:ok, records} <- ResultStore.list_run_records(store, []),
         context = %{record_count: length(records), groups: build_scout_context(records)},
         {:ok, assessment} <- run_scout(context, opts),
         assessment =
           assessment
           |> merge_group_facts(context.groups)
           |> then(&%{&1 | assessed_at: &1.assessed_at || DateTime.utc_now(), record_count: context.record_count}),
         :ok <- save_assessment(assessment, opts) do
      {:ok, assessment}
    end
  end

  @doc """
  Recommends an agent by matching `facets` against the scout's per-facet assessment.

  An unmeasured facet (no matching entry) routes `:explore`. A missing assessment
  falls back to the configured default dispatch agent.
  """
  @spec recommend(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def recommend(facets, opts \\ []) when is_map(facets) and is_list(opts) do
    facets = normalize_facet(facets)

    case read_assessment(opts) do
      :no_data ->
        {:ok, fallback_recommendation(facets, opts)}

      {:ok, %Assessment{} = assessment} ->
        {:ok, recommend_from_assessment(facets, assessment, opts)}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Predicts routing facets from a roadmap domain tag (backward-compatible shim)."
  @spec facets_from_domain(atom()) :: %{String.t() => term()}
  def facets_from_domain(domain) when is_atom(domain), do: %{"surface" => Atom.to_string(domain)}

  @doc false
  @spec assessment_path(keyword()) :: String.t()
  def assessment_path(opts) when is_list(opts) do
    Keyword.get(opts, :assessment_path) ||
      Path.join(assessment_root(opts), @artifact_basename)
  end

  @doc false
  @spec artifact_rel_path() :: String.t()
  def artifact_rel_path, do: @artifact_rel

  @spec run_scout(map(), keyword()) :: {:ok, assessment()} | {:error, term()}
  defp run_scout(context, opts) do
    case Application.get_env(:harness, :capability_scout) do
      fun when is_function(fun, 1) ->
        fun.(context)

      _other ->
        spawn_scout(context, opts)
    end
  end

  @spec spawn_scout(map(), keyword()) :: {:ok, assessment()} | {:error, term()}
  # sobelow_skip ["Traversal.FileModule"]
  defp spawn_scout(context, opts) do
    scratch = scratch_dir(opts)

    try do
      with {:ok, _agent, adapter} <- resolve_scout_adapter(opts),
           {:ok, %Outcome{}} <- Driver.run(adapter, scout_invocation(context, scratch), driver_opts(opts)) do
        read_scout_artifact(scratch)
      end
    after
      File.rm_rf(scratch)
    end
  end

  @spec scout_invocation(map(), String.t()) :: Invocation.t()
  defp scout_invocation(context, scratch) do
    %Invocation{
      prompt: scout_prompt(context),
      cwd: scratch,
      log_tag: "facet-scout",
      rule_content: AgentRules.render(),
      permission_mode: :autonomous
    }
  end

  @spec scout_prompt(map()) :: String.t()
  defp scout_prompt(%{record_count: count, groups: groups}) do
    facts_json = Jason.encode!(groups, pretty: true)

    """
    You are the harness routing scout. Read the per-facet agent fact ledgers below
    (approve rate, first-try rate, reviewer ratings, cost-to-green — already
    counted by harness; do NOT recompute or weight them). For EACH facet group,
    decide which agent wins on balance of approve / first-try / reviewer-quality
    / cost, and explain why in plain prose.

    Write your verdict as JSON to `#{@artifact_rel}` (relative to your working
    directory) and exit. Writing that file is the whole job; you change no code.

    ## Required JSON shape

        {
          "assessed_at": "<ISO-8601 UTC timestamp>",
          "entries": [
            {
              "facet": {"language": "elixir", "surface": "otp", ...},
              "winner": "codex",
              "reasoning": "why this agent wins this task-kind"
            }
          ]
        }

    Rules:
    - One entry per input facet group (including the empty `{}` unfaceted bucket).
    - `winner` is a harness agent name: claude | codex | cursor | grok | antigravity | pi.
    - `reasoning` is required — the routing rationale an orchestrator can read.
    - Never emit composite scores, weights, or numeric rankings.

    ## Input (#{count} run record(s), #{length(groups)} facet group(s))

    #{facts_json}
    """
  end

  @spec recommend_from_assessment(map(), assessment(), keyword()) :: map()
  defp recommend_from_assessment(facets, %Assessment{} = assessment, opts) do
    agents = agents(opts)

    case find_matching_entry(assessment, facets) do
      %Entry{} = entry ->
        Recommendation.new(
          agent: entry.winner,
          facets: facets,
          strategy: :exploit,
          rationale: entry.reasoning,
          scout_reasoning: entry.reasoning,
          matched_facet: entry.facet,
          ranked: ranked_from_entry(entry, agents)
        )

      nil ->
        explore_recommendation(facets, agents, opts)
    end
  end

  @spec explore_recommendation(map(), [atom()], keyword()) :: map()
  defp explore_recommendation(facets, agents, opts) do
    fallback = Keyword.get(opts, :fallback_agent, Config.get({:dispatch, :default_agent}))
    agent = Enum.find(agents, &(&1 == fallback)) || hd(agents)

    Recommendation.new(
      agent: agent,
      facets: facets,
      strategy: :explore,
      rationale: :unmeasured_facet,
      scout_reasoning: nil,
      matched_facet: nil,
      ranked: Enum.map(agents, &%{agent: &1, measurement: :unmeasured})
    )
  end

  @spec fallback_recommendation(map(), keyword()) :: map()
  defp fallback_recommendation(facets, opts) do
    agents = agents(opts)
    fallback = Keyword.get(opts, :fallback_agent, Config.get({:dispatch, :default_agent}))
    agent = Enum.find(agents, &(&1 == fallback)) || hd(agents)

    Recommendation.new(
      agent: agent,
      facets: facets,
      strategy: :fallback_no_data,
      rationale: :no_assessment,
      scout_reasoning: nil,
      matched_facet: nil,
      ranked: Enum.map(agents, &%{agent: &1, measurement: :unmeasured})
    )
  end

  @spec ranked_from_entry(entry(), [atom()]) :: [map()]
  defp ranked_from_entry(%Entry{winner: winner, by_agent: by_agent}, agents) do
    requested_agents = MapSet.new(agents)

    measured =
      by_agent
      |> Enum.reduce([], fn {agent, _facts}, acc ->
        if MapSet.member?(requested_agents, agent), do: [agent | acc], else: acc
      end)
      |> Enum.sort()

    winner_row = %{agent: winner, measurement: :measured, role: :winner}
    other_rows = for agent <- measured, agent != winner, do: %{agent: agent, measurement: :measured, role: :runner_up}
    unmeasured = for agent <- agents, agent not in measured, do: %{agent: agent, measurement: :unmeasured}

    [winner_row | other_rows ++ unmeasured]
  end

  @spec find_matching_entry(assessment(), map()) :: entry() | nil
  defp find_matching_entry(%Assessment{entries: entries}, facets) do
    normalized = normalize_facet(facets)

    entries
    |> Enum.map(&{facet_overlap(normalize_facet(&1.facet), normalized), &1})
    |> Enum.filter(fn {score, _entry} -> score > 0 end)
    |> case do
      [] ->
        nil

      scored ->
        {_score, entry} =
          Enum.max_by(scored, fn {score, entry} ->
            {score, exact_facet_match?(entry.facet, normalized)}
          end)

        entry
    end
  end

  @spec merge_group_facts(assessment(), [map()]) :: assessment()
  defp merge_group_facts(%Assessment{} = assessment, groups) when is_list(groups) do
    facts_by_facet =
      Map.new(groups, fn %{facet: facet, by_agent: facts} ->
        {facet_key(normalize_facet(facet)), facts}
      end)

    entries =
      Enum.map(assessment.entries, fn %Entry{} = entry ->
        %{entry | by_agent: Map.get(facts_by_facet, facet_key(entry.facet), entry.by_agent || %{})}
      end)

    %{assessment | entries: entries}
  end

  @spec facet_overlap(map(), map()) :: non_neg_integer()
  defp facet_overlap(left, right) do
    left
    |> Map.keys()
    |> Enum.count(fn key -> Map.get(right, key) == Map.get(left, key) end)
  end

  @spec exact_facet_match?(map(), map()) :: 0 | 1
  defp exact_facet_match?(left, right) do
    if normalize_facet(left) == normalize_facet(right), do: 1, else: 0
  end

  # sobelow_skip ["Traversal.FileModule"]
  @spec read_scout_artifact(String.t()) :: {:ok, assessment()} | {:error, term()}
  defp read_scout_artifact(scratch) do
    path = Path.join(scratch, @artifact_rel)

    case File.read(path) do
      {:ok, body} ->
        decode_assessment(body)

      {:error, :enoent} ->
        {:error, :missing_scout_artifact}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec decode_assessment(binary()) :: {:ok, assessment()} | {:error, term()}
  defp decode_assessment(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"entries" => entries} = decoded} when is_list(entries) ->
        with {:ok, decoded_entries} <- decode_entries(entries) do
          {:ok,
           %Assessment{
             assessed_at: assessed_at(decoded),
             record_count: Map.get(decoded, "record_count", 0),
             entries: decoded_entries
           }}
        end

      {:ok, other} ->
        {:error, {:malformed_assessment, other}}

      {:error, reason} ->
        {:error, {:invalid_json, reason}}
    end
  end

  @spec decode_entries([map()]) :: {:ok, [entry()]} | {:error, term()}
  defp decode_entries(entries) when is_list(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case decode_entry(entry) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  @spec decode_entry(map()) :: {:ok, entry()} | {:error, term()}
  defp decode_entry(%{"facet" => facet, "winner" => winner, "reasoning" => reasoning} = decoded)
       when is_map(facet) and is_binary(winner) and is_binary(reasoning) do
    with {:ok, winner} <- decode_agent(winner),
         {:ok, by_agent} <- decode_by_agent(Map.get(decoded, "by_agent", %{})) do
      {:ok,
       %Entry{
         facet: normalize_facet(facet),
         winner: winner,
         reasoning: reasoning,
         by_agent: by_agent
       }}
    end
  end

  defp decode_entry(other), do: {:error, {:invalid_assessment_entry, other}}

  @spec decode_by_agent(map()) :: {:ok, %{optional(atom()) => map()}} | {:error, term()}
  defp decode_by_agent(by_agent) when is_map(by_agent) do
    Enum.reduce_while(by_agent, {:ok, %{}}, fn {agent, facts}, {:ok, acc} ->
      case decode_agent(agent) do
        {:ok, decoded} -> {:cont, {:ok, Map.put(acc, decoded, facts)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec decode_agent(String.t()) :: {:ok, atom()} | {:error, term()}
  defp decode_agent(agent) when is_binary(agent) do
    @known_agent_names
    |> Map.fetch(String.downcase(agent))
    |> case do
      {:ok, known} -> {:ok, known}
      :error -> {:error, {:unknown_agent, agent}}
    end
  end

  @spec encode_assessment(assessment()) :: binary()
  defp encode_assessment(%Assessment{} = assessment) do
    Jason.encode!(
      %{
        "assessed_at" => datetime_iso(assessment.assessed_at),
        "record_count" => assessment.record_count,
        "entries" =>
          Enum.map(assessment.entries, fn %Entry{} = entry ->
            %{
              "facet" => entry.facet,
              "winner" => Atom.to_string(entry.winner),
              "reasoning" => entry.reasoning,
              "by_agent" => encode_by_agent(entry.by_agent)
            }
          end)
      },
      pretty: true
    )
  end

  @spec encode_by_agent(map()) :: map()
  defp encode_by_agent(by_agent) when is_map(by_agent) do
    Map.new(by_agent, fn {agent, facts} -> {Atom.to_string(agent), facts} end)
  end

  @spec assessed_at(map()) :: DateTime.t() | nil
  defp assessed_at(%{"assessed_at" => iso}) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp assessed_at(_decoded), do: nil

  @spec datetime_iso(DateTime.t() | nil) :: String.t() | nil
  defp datetime_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp datetime_iso(_other), do: nil

  @spec normalize_facet(term()) :: %{String.t() => term()}
  defp normalize_facet(facet), do: Facet.normalize(facet)

  @spec facet_key(map()) :: String.t()
  defp facet_key(facet) do
    facet
    |> normalize_facet()
    |> Enum.sort()
    |> Map.new()
    |> Jason.encode!()
  end

  @spec agents(keyword()) :: [atom()]
  defp agents(opts), do: Keyword.get(opts, :agents, AgentRegistry.agents() |> Map.keys() |> Enum.sort())

  @spec assessment_root(keyword()) :: String.t()
  defp assessment_root(opts) do
    opts
    |> Keyword.get(:assessment_root, @default_root)
    |> Path.expand()
  end

  # sobelow_skip ["Traversal.FileModule"]
  @spec scratch_dir(keyword()) :: String.t()
  defp scratch_dir(opts) do
    dir =
      Keyword.get_lazy(opts, :scratch_dir, fn ->
        Path.join(System.tmp_dir!(), "harness-scout-#{System.unique_integer([:positive])}")
      end)

    File.mkdir_p!(Path.join(dir, ".harness"))
    dir
  end

  @spec resolve_scout_adapter(keyword()) :: {:ok, atom(), module()} | {:error, term()}
  defp resolve_scout_adapter(opts) do
    agent =
      opts
      |> Keyword.get(:scout_adapter)
      |> case do
        agent when is_atom(agent) -> agent
        _ -> Application.get_env(:harness, :capability_scout_adapter, @default_adapter)
      end

    case AgentRegistry.delegatable_module_for_agent(agent) do
      {:ok, module} -> {:ok, agent, module}
      {:error, reason} -> {:error, {:no_scout_adapter, reason}}
    end
  end

  @spec driver_opts(keyword()) :: keyword()
  defp driver_opts(opts) do
    config = Application.get_env(:harness, :capability_scout, [])

    [
      idle_timeout: Keyword.get(opts, :idle_timeout, Keyword.get(config, :idle_timeout, @default_idle_timeout)),
      total_timeout: Keyword.get(opts, :total_timeout, Keyword.get(config, :total_timeout, @default_total_timeout))
    ]
  end
end
