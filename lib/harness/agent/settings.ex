defmodule Harness.Agent.Settings do
  @moduledoc """
  Persisted, runtime-flippable operator enable/disable for dispatchable agents.

  An operator takes an agent out of rotation (a flaky CLI, an exhausted paid
  plan, a model under evaluation) from the dashboard; the choice persists across
  a BEAM restart. This is the operator-intent gate that composes with — but is
  deliberately distinct from — `Harness.AgentRegistry`'s transient,
  clears-on-restart `available?/1` quota hint: disabling is a durable decision,
  quota-unavailability is a soft latency optimization.

  ## One Postgres table, read directly

  Every read goes straight to `Harness.SettingsStore` (Postgres when
  `:repo_enabled`), so the table is the single source of truth — no app-env
  overlay cache to drift, no boot loader to forget. `disabled?/1` and
  `reviewer_eligible?/1` are consulted on the dispatch / review-gate paths
  (selection happens per run, not in a hot loop), so the read cost is warm-path.

  ## Two independent axes

  Stored as the *disabled* set (a list of agent atoms) and a *reviewer-ineligible*
  set under one record. **Absence of an agent from the disabled set means
  enabled**, so a freshly added adapter is dispatchable by default and only an
  explicit operator toggle removes it. Reviewer ineligibility is separate: an
  agent can implement yet be barred from the review gate (Pi/OSS models). When
  no reviewer override has ever been persisted, `reviewer_ineligible_agents/0`
  uses the in-code default seed (`[:pi]`); once set, the persisted value — even
  an empty list — is authoritative.

  With `repo_enabled: false` the store is ephemeral, so every agent reads as
  enabled and reviewer-eligible-by-seed (the dashboard surfaces the ephemerality).
  """

  alias Harness.SettingsStore

  require Logger

  @store_key :agent
  @default_reviewer_ineligible [:pi]

  @typedoc """
  The persisted settings-store value: the operator-disabled set (implementer
  enablement) and the reviewer-ineligible set (review-gate eligibility), two
  independent axes.
  """
  @type t :: %{:disabled => [atom()], optional(:reviewer_ineligible) => [atom()]}

  @doc "Returns whether an agent is operator-enabled (absence ⇒ enabled)."
  @spec enabled?(atom()) :: boolean()
  def enabled?(agent) when is_atom(agent), do: not disabled?(agent)

  @doc "Returns whether an agent has been operator-disabled."
  @spec disabled?(atom()) :: boolean()
  def disabled?(agent) when is_atom(agent), do: agent in disabled_agents()

  @doc "Returns the list of operator-disabled agent atoms (read from the store)."
  @spec disabled_agents() :: [atom()]
  def disabled_agents do
    record() |> Map.get(:disabled, []) |> Enum.filter(&is_atom/1)
  end

  @doc """
  Enables or disables an agent at runtime, persists the change, and logs an
  info-level audit line naming the actor.
  """
  @spec set_enabled(atom(), boolean(), String.t()) :: :ok
  def set_enabled(agent, enabled, actor) when is_atom(agent) and is_boolean(enabled) and is_binary(actor) do
    rec = record()
    disabled = Map.get(rec, :disabled, [])

    next =
      if enabled,
        do: List.delete(disabled, agent),
        else: Enum.uniq([agent | disabled])

    persist(Map.put(rec, :disabled, next))
    Logger.info("harness agent: #{agent} #{state_word(enabled)} by #{actor}")
    :ok
  end

  @doc """
  Returns whether an agent may be picked as THE reviewer gate. Distinct from
  `enabled?/1`: an agent can be enabled to implement yet ineligible to review
  (e.g. Pi/OSS models, ineligible by default until trusted to run the checks +
  write a sound verdict). Absence ⇒ eligible, with `[:pi]` as the code default
  before any operator override is persisted.
  """
  @spec reviewer_eligible?(atom()) :: boolean()
  def reviewer_eligible?(agent) when is_atom(agent), do: not reviewer_ineligible?(agent)

  @doc "Returns whether an agent has been marked ineligible as a reviewer."
  @spec reviewer_ineligible?(atom()) :: boolean()
  def reviewer_ineligible?(agent) when is_atom(agent), do: agent in reviewer_ineligible_agents()

  @doc """
  Returns the reviewer-ineligible agent atoms. Falls back to the in-code seed
  until an operator override is persisted — so the stopgap holds on first boot
  and when persistence is off without consulting app env at runtime.
  """
  @spec reviewer_ineligible_agents() :: [atom()]
  def reviewer_ineligible_agents do
    case Map.fetch(record(), :reviewer_ineligible) do
      {:ok, list} when is_list(list) -> Enum.filter(list, &is_atom/1)
      _unset -> @default_reviewer_ineligible
    end
  end

  @doc """
  Sets an agent's reviewer eligibility at runtime, persists it, and logs an
  audit line. Once set, the persisted value is authoritative over the config seed
  (an empty list makes a previously-seeded agent eligible and survives restart).
  """
  @spec set_reviewer_eligible(atom(), boolean(), String.t()) :: :ok
  def set_reviewer_eligible(agent, eligible, actor) when is_atom(agent) and is_boolean(eligible) and is_binary(actor) do
    ineligible = reviewer_ineligible_agents()

    next =
      if eligible,
        do: List.delete(ineligible, agent),
        else: Enum.uniq([agent | ineligible])

    persist(Map.put(record(), :reviewer_ineligible, next))
    Logger.info("harness agent: #{agent} reviewer-#{eligibility_word(eligible)} by #{actor}")
    :ok
  end

  @spec state_word(boolean()) :: String.t()
  defp state_word(true), do: "enabled"
  defp state_word(false), do: "disabled"

  @spec eligibility_word(boolean()) :: String.t()
  defp eligibility_word(true), do: "eligible"
  defp eligibility_word(false), do: "ineligible"

  # The current persisted record, or an empty map (ephemeral store / no row yet).
  # `set_*` preserves the other axis by writing this map back with one key
  # replaced — so a `set_enabled` toggle never materializes the reviewer seed.
  @spec record() :: map()
  defp record do
    case SettingsStore.fetch(@store_key) do
      {:ok, map} when is_map(map) -> map
      _missing_or_invalid -> %{}
    end
  end

  @spec persist(t()) :: :ok | {:error, term()}
  defp persist(record), do: SettingsStore.put(@store_key, record)
end
