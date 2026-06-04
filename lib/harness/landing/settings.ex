defmodule Harness.Landing.Settings do
  @moduledoc """
  Persisted, runtime-flippable per-project landing policy — the operator surface
  for autonomous merge.

  A project's `%Harness.Project{}` carries a *default* `landing_policy`
  (`:manual` | `:auto`) and `target_branch`. Those are registration-time identity;
  this module is the **overlay** an operator flips at runtime from the dashboard,
  the same way `Harness.Cron.Settings` / `Harness.Agent.Settings` overlay autonomy
  and agent enablement. A run never auto-merges until an operator opts the project
  into `:auto` **with a target branch** — the missing UI control that previously
  forced hand-editing the registry via `iex`.

  ## App env is the live cache; SettingsStore is the persistence layer

  `Harness.Run` reads the *effective* project (`overlay/1`) when a run starts, so a
  flip takes effect on the next run with no restart. Every setter writes app env
  (the value `overlay/1` reads) **and** write-throughs to
  `Harness.SettingsStore` so the choice survives a BEAM restart. `load_into_env/0`
  runs once on boot to seed app env from the shared store.

  ## The footgun guard

  `set/4` refuses `:auto` without a non-empty `target_branch` (`{:error,
  :target_branch_required}`) — arming auto-merge with nowhere to merge is never a
  valid state. `:manual` clears the target branch.

  ## Disabling

  `config :harness, :landing_settings, false` (or `nil`) short-circuits
  persistence: setters still update app env (runtime flips work) but nothing is
  written, and `load_into_env/0` is a no-op. Otherwise the legacy root is used
  by the file fallback and for first-boot import of old `landing_settings.term`
  files.
  """

  alias Harness.Project
  alias Harness.SettingsStore

  require Logger

  @default_root "~/.harness"
  @filename "landing_settings.term"
  @store_key :landing
  @env_key :landing_overrides
  @valid_policies [:manual, :auto]

  @typedoc "A single project's runtime override: landing policy and/or reviewer pin."
  @type override :: %{
          optional(:landing_policy) => Project.landing_policy(),
          optional(:target_branch) => String.t() | nil,
          optional(:reviewer) => atom() | nil
        }

  @typedoc "The persisted settings-store value: project name => override."
  @type record :: %{String.t() => override()}

  @doc """
  Seeds app env from the persisted store. Called once on boot so `overlay/1`
  reflects the persisted overrides from t=0.

  No file (or a disabled store) leaves the registration-time defaults in place.
  """
  @spec load_into_env() :: :ok
  def load_into_env do
    case SettingsStore.fetch(@store_key, store_opts()) do
      {:ok, map} when is_map(map) ->
        Application.put_env(:harness, @env_key, sanitize(map))
        :ok

      _missing_or_invalid ->
        :ok
    end
  end

  @doc """
  Overlays the persisted landing override (if any) onto a project, returning the
  *effective* project. A project with no override is returned unchanged, so its
  registration-time `landing_policy` / `target_branch` stand.
  """
  @spec overlay(Project.t()) :: Project.t()
  def overlay(%Project{name: name} = project) do
    case Map.get(overrides(), name) do
      %{} = override ->
        project
        |> overlay_landing(override)
        |> overlay_reviewer(override)

      _none ->
        project
    end
  end

  @doc """
  Returns the effective landing override for a project (the persisted override, or
  the project's own registration-time values) — the view-model the dashboard reads.
  """
  @spec effective(Project.t()) :: override()
  def effective(%Project{} = project) do
    effective = overlay(project)
    %{landing_policy: effective.landing_policy, target_branch: effective.target_branch, reviewer: effective.reviewer}
  end

  @doc """
  Sets a project's landing override at runtime, persists it, and logs an
  info-level audit line naming the actor.

  `:auto` requires a non-empty `target_branch` — `{:error, :target_branch_required}`
  otherwise. `:manual` ignores and clears the branch. An unknown policy is rejected.
  """
  @spec set(String.t(), Project.landing_policy(), String.t() | nil, String.t()) ::
          :ok | {:error, :target_branch_required | :invalid_policy}
  def set(name, :auto, branch, actor) when is_binary(name) and is_binary(actor) do
    case normalize_branch(branch) do
      nil -> {:error, :target_branch_required}
      trimmed -> put_and_persist(name, %{landing_policy: :auto, target_branch: trimmed}, actor)
    end
  end

  def set(name, :manual, _branch, actor) when is_binary(name) and is_binary(actor) do
    put_and_persist(name, %{landing_policy: :manual, target_branch: nil}, actor)
  end

  def set(name, policy, _branch, actor) when is_binary(name) and is_binary(actor) and policy not in @valid_policies do
    {:error, :invalid_policy}
  end

  @doc """
  Sets or clears a project's reviewer override at runtime, preserving any landing
  override already stored for the project.
  """
  @spec set_reviewer(String.t(), atom() | nil, String.t()) :: :ok
  def set_reviewer(name, reviewer, actor)
      when is_binary(name) and (is_atom(reviewer) or is_nil(reviewer)) and is_binary(actor) do
    put_and_persist(name, %{reviewer: reviewer}, actor)
  end

  @spec put_and_persist(String.t(), override(), String.t()) :: :ok
  defp put_and_persist(name, override, actor) do
    Application.put_env(
      :harness,
      @env_key,
      Map.put(overrides(), name, Map.merge(Map.get(overrides(), name, %{}), override))
    )

    persist()
    Logger.info("harness landing: #{name} -> #{describe(override)} by #{actor}")
    :ok
  end

  @spec describe(override()) :: String.t()
  defp describe(%{landing_policy: :auto, target_branch: branch}), do: "auto-land to #{branch}"
  defp describe(%{landing_policy: :manual}), do: "manual"
  defp describe(%{reviewer: nil}), do: "reviewer auto"
  defp describe(%{reviewer: reviewer}), do: "reviewer #{reviewer}"

  @spec overlay_landing(Project.t(), override()) :: Project.t()
  defp overlay_landing(project, %{landing_policy: policy, target_branch: branch}) do
    %{project | landing_policy: policy, target_branch: branch}
  end

  defp overlay_landing(project, _override), do: project

  @spec overlay_reviewer(Project.t(), override()) :: Project.t()
  defp overlay_reviewer(project, override) do
    if Map.has_key?(override, :reviewer) do
      %{project | reviewer: Map.get(override, :reviewer)}
    else
      project
    end
  end

  # nil ⇒ no usable branch (absent / blank); otherwise the trimmed branch.
  @spec normalize_branch(term()) :: String.t() | nil
  defp normalize_branch(branch) when is_binary(branch) do
    case String.trim(branch) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_branch(_other), do: nil

  @spec overrides() :: record()
  defp overrides, do: Application.get_env(:harness, @env_key, %{})

  # Keeps only well-formed `{policy, branch}` entries from a loaded file, so a
  # torn or hand-edited term can't inject a malformed override into app env.
  @spec sanitize(map()) :: record()
  defp sanitize(map) do
    for {name, override} <- map,
        is_binary(name),
        sanitized = sanitize_override(override),
        not is_nil(sanitized),
        into: %{},
        do: {name, sanitized}
  end

  @spec sanitize_override(term()) :: override() | nil
  defp sanitize_override(%{} = override) do
    %{}
    |> sanitize_landing(override)
    |> sanitize_reviewer(override)
    |> case do
      clean when map_size(clean) == 0 -> nil
      clean -> clean
    end
  end

  defp sanitize_override(_override), do: nil

  @spec sanitize_landing(override(), map()) :: override()
  defp sanitize_landing(base, %{landing_policy: policy, target_branch: branch})
       when policy in @valid_policies and (is_binary(branch) or is_nil(branch)) do
    Map.merge(base, %{landing_policy: policy, target_branch: branch})
  end

  defp sanitize_landing(base, _override), do: base

  @spec sanitize_reviewer(override(), map()) :: override()
  defp sanitize_reviewer(base, %{reviewer: reviewer}) when is_atom(reviewer) or is_nil(reviewer) do
    Map.put(base, :reviewer, reviewer)
  end

  defp sanitize_reviewer(base, _override), do: base

  @spec persist() :: :ok | {:error, term()}
  defp persist do
    SettingsStore.put(@store_key, overrides(), store_opts())
  end

  @spec store_opts() :: SettingsStore.legacy_opts()
  defp store_opts, do: [legacy_config_key: :landing_settings, legacy_filename: @filename, default_root: @default_root]
end
