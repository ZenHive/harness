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

  @typedoc "The persisted record: the set of operator-disabled agent atoms."
  @type record :: %{disabled: [atom()]}

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
          {:ok, %{disabled: disabled}} when is_list(disabled) ->
            Application.put_env(:harness, @env_key, Enum.filter(disabled, &is_atom/1))
            :ok

          _other ->
            :ok
        end
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

  @spec state_word(boolean()) :: String.t()
  defp state_word(true), do: "enabled"
  defp state_word(false), do: "disabled"

  @spec persist() :: :ok | {:error, term()}
  defp persist do
    case root() do
      nil -> :ok
      dir -> TermCodec.write_file(path(dir), %{disabled: disabled_agents()})
    end
  end

  @spec path(String.t()) :: String.t()
  defp path(dir), do: Path.join(dir, @filename)

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
