defmodule Harness.Cron.Settings do
  @moduledoc """
  Persisted, runtime-flippable autonomy switches for cron-driven roadmap polling
  (Tasks 109 + 110).

  Two switches govern unattended dispatch of code-writing agents:

    * the **master** flag — the fleet-wide kill-switch, stored in the existing
      `:harness, :cron_polling` `:enabled` key so `Harness.Cron.RoadmapPoller`'s
      `enabled?/0` and `status/0` already reflect it;
    * a **per-project** flag — a `%{project_name => boolean()}` map under
      `:harness, :cron_project_autonomy`. **Absence means OFF**, so a freshly
      registered project is non-autonomous until an operator opts it in.

  Effective autonomy for a project is `master AND project` (`effective?/1`).

  ## App env is the live cache; the file is the persistence layer

  `RoadmapPoller.perform/1` already reads `enabled?/0` from app env on every tick,
  so a flip takes effect at the next tick with no restart. This module keeps that
  model: every setter writes app env (the value the poller reads) **and**
  write-throughs to a file so the choice survives a BEAM restart. `load_into_env/0`
  runs once on boot to seed app env from the file before Oban starts.

  Mirrors `Harness.Chat.Store`: a single Erlang external-term file written via a
  `.tmp` sibling + atomic rename, so a concurrent reader never sees a torn file.
  File-backed (not Ecto) deliberately — two booleans do not justify the project's
  first Ecto schema + sandbox apparatus, and a config-file store is the precedent
  `Harness.Chat.Store` already sets.

  ## Disabling

  `config :harness, :cron_settings, false` (or `nil`) short-circuits persistence:
  setters still update app env (runtime flips work) but nothing is written, and
  `load_into_env/0` is a no-op. Otherwise configure the root with
  `config :harness, :cron_settings, root: "/some/path"`.
  """

  alias Harness.Project

  require Logger

  @default_root "~/.harness"
  @filename "cron_settings.term"

  @typedoc "The persisted record: both switch sets in one term file."
  @type record :: %{master_enabled: boolean(), project_autonomy: %{String.t() => boolean()}}

  @doc """
  Seeds app env from the persisted file. Called once on boot, before Oban starts,
  so `RoadmapPoller.enabled?/0` reflects the persisted master flag from t=0.

  No file (or a disabled store) leaves the compile-time config defaults in place.
  """
  @spec load_into_env() :: :ok
  def load_into_env do
    case root() do
      nil ->
        :ok

      dir ->
        case read_term(path(dir)) do
          {:ok, %{master_enabled: master, project_autonomy: projects}}
          when is_boolean(master) and is_map(projects) ->
            put_master(master)
            Application.put_env(:harness, :cron_project_autonomy, projects)
            :ok

          _other ->
            :ok
        end
    end
  end

  @doc "Returns whether the fleet-wide master autonomy switch is on."
  @spec master_enabled?() :: boolean()
  def master_enabled? do
    :harness
    |> Application.get_env(:cron_polling, [])
    |> Keyword.get(:enabled, false)
    |> Kernel.==(true)
  end

  @doc "Returns whether a project's own autonomy flag is on (absence ⇒ false)."
  @spec project_enabled?(Project.t() | String.t()) :: boolean()
  def project_enabled?(%Project{name: name}), do: project_enabled?(name)
  def project_enabled?(name) when is_binary(name), do: Map.get(project_map(), name, false)

  @doc """
  Returns the effective autonomy for a project: `master AND project`. This is the
  truth the poller acts on — the master flag is the single incident kill-switch.
  """
  @spec effective?(Project.t()) :: boolean()
  def effective?(%Project{} = project), do: master_enabled?() and project_enabled?(project)

  @doc """
  Flips the master switch at runtime, persists it, and logs an info-level audit
  line naming the actor.
  """
  @spec set_master(boolean(), String.t()) :: :ok
  def set_master(enabled, actor) when is_boolean(enabled) and is_binary(actor) do
    put_master(enabled)
    persist()
    Logger.info("harness cron autonomy: master #{state_word(enabled)} by #{actor}")
    :ok
  end

  @doc """
  Flips a single project's autonomy flag at runtime, persists it, and logs an
  info-level audit line naming the actor.
  """
  @spec set_project(String.t(), boolean(), String.t()) :: :ok
  def set_project(name, enabled, actor) when is_binary(name) and is_boolean(enabled) and is_binary(actor) do
    Application.put_env(:harness, :cron_project_autonomy, Map.put(project_map(), name, enabled))
    persist()
    Logger.info("harness cron autonomy: project #{name} #{state_word(enabled)} by #{actor}")
    :ok
  end

  @spec project_map() :: %{String.t() => boolean()}
  defp project_map, do: Application.get_env(:harness, :cron_project_autonomy, %{})

  # Writes the master flag into the existing :cron_polling config, preserving the
  # schedule (and any other keys) so RoadmapPoller's reads are unaffected.
  @spec put_master(boolean()) :: :ok
  defp put_master(enabled) do
    config = Application.get_env(:harness, :cron_polling, [])
    Application.put_env(:harness, :cron_polling, Keyword.put(config, :enabled, enabled))
  end

  @spec state_word(boolean()) :: String.t()
  defp state_word(true), do: "enabled"
  defp state_word(false), do: "disabled"

  @spec persist() :: :ok | {:error, term()}
  defp persist do
    case root() do
      nil -> :ok
      dir -> write_term(path(dir), current_state())
    end
  end

  @spec current_state() :: record()
  defp current_state do
    %{master_enabled: master_enabled?(), project_autonomy: project_map()}
  end

  @spec path(String.t()) :: String.t()
  defp path(dir), do: Path.join(dir, @filename)

  # Write to a `.tmp` sibling then atomically rename (POSIX, same filesystem) so a
  # concurrent reader never observes a half-written term file.
  # sobelow_skip ["Traversal.FileModule"]
  @spec write_term(String.t(), term()) :: :ok | {:error, term()}
  defp write_term(path, term) do
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, :erlang.term_to_binary(term)) do
      File.rename(tmp, path)
    end
  end

  # Decodes WITHOUT [:safe]: a harness-owned file written by this app's own
  # term_to_binary, not untrusted input. The rescue still catches torn bytes.
  # sobelow_skip ["Traversal.FileModule", "Misc.BinToTerm"]
  @spec read_term(String.t()) :: {:ok, term()} | {:error, term()}
  defp read_term(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, :erlang.binary_to_term(body)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    ArgumentError -> {:error, {:invalid_term_file, path}}
  end

  # nil ⇒ store disabled; otherwise an expanded absolute root directory.
  @spec root() :: String.t() | nil
  defp root do
    case Application.get_env(:harness, :cron_settings, root: @default_root) do
      false -> nil
      nil -> nil
      opts when is_list(opts) -> opts |> Keyword.get(:root, @default_root) |> Path.expand()
    end
  end
end
