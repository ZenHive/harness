defmodule Harness.Agent.Settings do
  @moduledoc """
  Persisted, runtime-flippable operator enable/disable for dispatchable agents.

  An operator takes an agent out of rotation (a flaky CLI, an exhausted paid
  plan, a model under evaluation) from the dashboard; the choice persists across
  a BEAM restart. This is the operator-intent gate that composes with — but is
  deliberately distinct from — `Harness.AgentRegistry`'s transient,
  clears-on-restart `available?/1` quota hint: disabling is a durable decision,
  quota-unavailability is a soft latency optimization.

  ## Default ON, disable is opt-in

  Stored as the *disabled* set under `:harness, :agent_disabled` (a list of agent
  atoms). **Absence means enabled**, so a freshly added adapter is dispatchable
  by default and only an explicit operator toggle removes it — the opposite
  default from per-project cron autonomy (off-by-default for safety), because an
  unknown agent failing a dispatch is cheap and recoverable, whereas silently
  disabling a new agent would be surprising.

  ## App env is the live cache; the file is the persistence layer

  `Harness.AgentRegistry.select/2` reads `disabled?/1` from app env on every
  dispatch, so a toggle takes effect on the next selection with no restart. Every
  setter writes app env **and** write-throughs to a `.tmp`+rename term file so the
  choice survives a restart. `load_into_env/0` runs once on boot to seed app env
  from the file. Mirrors `Harness.Cron.Settings` / `Harness.Chat.Store`.

  ## Disabling

  `config :harness, :agent_settings, false` (or `nil`) short-circuits persistence:
  setters still update app env (runtime flips work) but nothing is written, and
  `load_into_env/0` is a no-op. Otherwise configure the root with
  `config :harness, :agent_settings, root: "/some/path"`.
  """

  alias Harness.TermCodec

  require Logger

  @default_root "~/.harness"
  @filename "agent_settings.term"
  @env_key :agent_disabled
  @reviewer_env_key :agent_reviewer_ineligible

  @typedoc """
  The persisted record: the operator-disabled set (implementer enablement) and
  the reviewer-ineligible set (review-gate eligibility), two independent axes.
  """
  @type record :: %{:disabled => [atom()], optional(:reviewer_ineligible) => [atom()]}

  @doc """
  Seeds app env from the persisted file. Called once on boot, before any dispatch
  path reads `disabled?/1`, so an operator's last choice is in force from t=0.

  No file (or a disabled store) leaves every agent enabled.
  """
  @spec load_into_env() :: :ok
  def load_into_env do
    case root() do
      nil ->
        :ok

      dir ->
        case TermCodec.read_file(path(dir)) do
          {:ok, record} when is_map(record) ->
            load_key(record, :disabled, @env_key)
            load_key(record, :reviewer_ineligible, @reviewer_env_key)
            :ok

          _other ->
            :ok
        end
    end
  end

  # Loads one persisted agent-atom set into its app-env cache. An absent key is
  # left unset: `disabled_agents/0` then defaults to enabled, and
  # `reviewer_ineligible_agents/0` falls back to the `:reviewer_exclude` config
  # seed — so an old-format file (only `:disabled`) keeps the `[:pi]` stopgap.
  @spec load_key(map(), atom(), atom()) :: :ok
  defp load_key(record, key, env_key) do
    case Map.get(record, key) do
      list when is_list(list) -> Application.put_env(:harness, env_key, Enum.filter(list, &is_atom/1))
      _other -> :ok
    end
  end

  @doc "Returns whether an agent is operator-enabled (absence ⇒ enabled)."
  @spec enabled?(atom()) :: boolean()
  def enabled?(agent) when is_atom(agent), do: not disabled?(agent)

  @doc "Returns whether an agent has been operator-disabled."
  @spec disabled?(atom()) :: boolean()
  def disabled?(agent) when is_atom(agent), do: agent in disabled_agents()

  @doc "Returns the list of operator-disabled agent atoms."
  @spec disabled_agents() :: [atom()]
  def disabled_agents, do: Application.get_env(:harness, @env_key, [])

  @doc """
  Enables or disables an agent at runtime, persists the change, and logs an
  info-level audit line naming the actor.
  """
  @spec set_enabled(atom(), boolean(), String.t()) :: :ok
  def set_enabled(agent, enabled, actor) when is_atom(agent) and is_boolean(enabled) and is_binary(actor) do
    disabled = disabled_agents()

    next =
      if enabled,
        do: List.delete(disabled, agent),
        else: Enum.uniq([agent | disabled])

    Application.put_env(:harness, @env_key, next)
    persist()
    Logger.info("harness agent: #{agent} #{state_word(enabled)} by #{actor}")
    :ok
  end

  @doc """
  Returns whether an agent may be picked as THE reviewer gate. Distinct from
  `enabled?/1`: an agent can be enabled to implement yet ineligible to review
  (e.g. Pi/OSS models, ineligible by default until trusted to run the checks +
  write a sound verdict). Absence ⇒ eligible, with the `:reviewer_exclude` config
  ([:pi]) as the first-boot seed before any operator override is persisted.
  """
  @spec reviewer_eligible?(atom()) :: boolean()
  def reviewer_eligible?(agent) when is_atom(agent), do: not reviewer_ineligible?(agent)

  @doc "Returns whether an agent has been marked ineligible as a reviewer."
  @spec reviewer_ineligible?(atom()) :: boolean()
  def reviewer_ineligible?(agent) when is_atom(agent), do: agent in reviewer_ineligible_agents()

  @doc """
  Returns the reviewer-ineligible agent atoms. Falls back to the
  `:reviewer_exclude` config seed (default `[:pi]`) until an operator override is
  persisted — so the stopgap holds on first boot and when persistence is off.
  """
  @spec reviewer_ineligible_agents() :: [atom()]
  def reviewer_ineligible_agents do
    case Application.get_env(:harness, @reviewer_env_key) do
      list when is_list(list) -> list
      _unset -> Application.get_env(:harness, :reviewer_exclude, [:pi])
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

    Application.put_env(:harness, @reviewer_env_key, next)
    persist()
    Logger.info("harness agent: #{agent} reviewer-#{eligibility_word(eligible)} by #{actor}")
    :ok
  end

  @spec state_word(boolean()) :: String.t()
  defp state_word(true), do: "enabled"
  defp state_word(false), do: "disabled"

  @spec eligibility_word(boolean()) :: String.t()
  defp eligibility_word(true), do: "eligible"
  defp eligibility_word(false), do: "ineligible"

  # Serializes only the axes that have an explicit value. `reviewer_ineligible`
  # is written ONLY when its env key is actually set (a real reviewer override
  # happened) — otherwise omitting it keeps reload falling back to the live
  # `:reviewer_exclude` seed, so an unrelated set_enabled toggle never freezes
  # the seed into the file. `:disabled` has no config seed (defaults to []), so
  # it is always safe to write.
  @spec persist() :: :ok | {:error, term()}
  defp persist do
    case root() do
      nil ->
        :ok

      dir ->
        record =
          case Application.get_env(:harness, @reviewer_env_key) do
            list when is_list(list) -> %{disabled: disabled_agents(), reviewer_ineligible: list}
            _unset -> %{disabled: disabled_agents()}
          end

        TermCodec.write_file(path(dir), record)
    end
  end

  @spec path(String.t()) :: String.t()
  defp path(dir), do: Path.join(dir, @filename)

  # TODO(Task 165): this store now carries TWO axes (disabled implementers +
  # reviewer_ineligible reviewers, Task 182) in one term file. When Task 165
  # folds the Cron/Agent/Landing domains onto the shared Postgres-backed store,
  # both Agent.Settings axes must move together — the consolidation owns this
  # file, not just the :disabled set.

  # nil ⇒ store disabled; otherwise an expanded absolute root directory.
  @spec root() :: String.t() | nil
  defp root do
    case Application.get_env(:harness, :agent_settings, root: @default_root) do
      false -> nil
      nil -> nil
      opts when is_list(opts) -> opts |> Keyword.get(:root, @default_root) |> Path.expand()
    end
  end
end
