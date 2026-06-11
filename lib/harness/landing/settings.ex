defmodule Harness.Landing.Settings do
  @moduledoc """
  Persisted, runtime-flippable per-project landing policy — the operator surface
  for autonomous merge.

  A project's `%Harness.Project{}` carries a *default* `landing_policy`
  (`:manual` | `:auto`) and `target_branch`. Those are registration-time identity;
  this module is the **override** an operator flips at runtime from the dashboard,
  the same way `Harness.Cron.Settings` / `Harness.Agent.Settings` overlay autonomy
  and agent enablement. A run never auto-merges until an operator opts the project
  into `:auto` **with a target branch**.

  ## One Postgres table, read directly

  `overlay/1` reads the persisted overrides straight from `Harness.SettingsStore`
  (Postgres when `:repo_enabled`) every time a run starts, so the table is the
  single source of truth — a flip takes effect on the next run and survives a
  restart with no boot loader and no app-env cache to drift. This is what fixed
  the silent landing-policy revert: the value lives in exactly one place.

  ## The footgun guard

  `set/4` refuses `:auto` without a non-empty `target_branch` (`{:error,
  :target_branch_required}`) — arming auto-merge with nowhere to merge is never a
  valid state. `:manual` clears the target branch.

  With `repo_enabled: false` the store is ephemeral: a flip is a no-op write and
  `overlay/1` always returns the project's registration-time defaults (the
  dashboard surfaces the ephemerality).
  """

  alias Harness.Project
  alias Harness.SettingsStore

  require Logger

  @store_key :landing
  @valid_policies [:manual, :auto]

  @typedoc "A single project's runtime override: landing policy and/or reviewer pin."
  @type override :: %{
          optional(:landing_policy) => Project.landing_policy(),
          optional(:target_branch) => String.t() | nil,
          optional(:reviewer) => atom() | nil
        }

  @typedoc "The persisted settings-store value: project name => override."
  @type t :: %{String.t() => override()}

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
    current = overrides()
    next = Map.put(current, name, Map.merge(Map.get(current, name, %{}), override))
    SettingsStore.put(@store_key, next)
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
    case Map.fetch(override, :reviewer) do
      {:ok, reviewer} -> %{project | reviewer: reviewer}
      :error -> project
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

  # The persisted overrides, sanitized — a torn or hand-edited term can't inject
  # a malformed override. Reads straight from the store (no app-env cache).
  @spec overrides() :: t()
  defp overrides do
    case SettingsStore.fetch(@store_key) do
      {:ok, map} when is_map(map) -> sanitize(map)
      _missing_or_invalid -> %{}
    end
  end

  # Keeps only well-formed `{policy, branch}` / reviewer entries.
  @spec sanitize(map()) :: t()
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
end
