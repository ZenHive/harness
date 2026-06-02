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

  ## App env is the live cache; the file is the persistence layer

  `Harness.Run` reads the *effective* project (`overlay/1`) when a run starts, so a
  flip takes effect on the next run with no restart. Every setter writes app env
  (the value `overlay/1` reads) **and** write-throughs to a file so the choice
  survives a BEAM restart. `load_into_env/0` runs once on boot to seed app env from
  the file.

  Mirrors `Harness.Cron.Settings` / `Harness.Chat.Store`: a single Erlang
  external-term file written via a `.tmp` sibling + atomic rename, so a concurrent
  reader never sees a torn file. File-backed (not Ecto) deliberately — a small
  per-project config map does not justify the project's first Ecto schema +
  sandbox apparatus, and it is the precedent the sibling settings stores set.

  ## The footgun guard

  `set/4` refuses `:auto` without a non-empty `target_branch` (`{:error,
  :target_branch_required}`) — arming auto-merge with nowhere to merge is never a
  valid state. `:manual` clears the target branch.

  ## Disabling

  `config :harness, :landing_settings, false` (or `nil`) short-circuits
  persistence: setters still update app env (runtime flips work) but nothing is
  written, and `load_into_env/0` is a no-op. Otherwise configure the root with
  `config :harness, :landing_settings, root: "/some/path"`.
  """

  alias Harness.Project

  require Logger

  @default_root "~/.harness"
  @filename "landing_settings.term"
  @env_key :landing_overrides
  @valid_policies [:manual, :auto]

  @typedoc "A single project's landing override: policy plus (for `:auto`) the merge target."
  @type override :: %{landing_policy: Project.landing_policy(), target_branch: String.t() | nil}

  @typedoc "The persisted record: project name => override."
  @type record :: %{String.t() => override()}

  @doc """
  Seeds app env from the persisted file. Called once on boot so `overlay/1`
  reflects the persisted overrides from t=0.

  No file (or a disabled store) leaves the registration-time defaults in place.
  """
  @spec load_into_env() :: :ok
  def load_into_env do
    case root() do
      nil ->
        :ok

      dir ->
        case read_term(path(dir)) do
          {:ok, map} when is_map(map) ->
            Application.put_env(:harness, @env_key, sanitize(map))
            :ok

          _other ->
            :ok
        end
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
      %{landing_policy: policy, target_branch: branch} ->
        %{project | landing_policy: policy, target_branch: branch}

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
    %{landing_policy: effective.landing_policy, target_branch: effective.target_branch}
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

  @spec put_and_persist(String.t(), override(), String.t()) :: :ok
  defp put_and_persist(name, override, actor) do
    Application.put_env(:harness, @env_key, Map.put(overrides(), name, override))
    persist()
    Logger.info("harness landing: #{name} -> #{describe(override)} by #{actor}")
    :ok
  end

  @spec describe(override()) :: String.t()
  defp describe(%{landing_policy: :auto, target_branch: branch}), do: "auto-land to #{branch}"
  defp describe(%{landing_policy: :manual}), do: "manual"

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
    for {name, %{landing_policy: policy, target_branch: branch}} <- map,
        is_binary(name),
        policy in @valid_policies,
        is_binary(branch) or is_nil(branch),
        into: %{},
        do: {name, %{landing_policy: policy, target_branch: branch}}
  end

  @spec persist() :: :ok | {:error, term()}
  defp persist do
    case root() do
      nil -> :ok
      dir -> write_term(path(dir), overrides())
    end
  end

  @spec path(String.t()) :: String.t()
  defp path(dir), do: Path.join(dir, @filename)

  # TODO(Task 165): this is the third+ copy of the .tmp+rename term-file plumbing
  # (Cron.Settings / Agent.Settings / Chat.Store) — the rule-of-three trigger that
  # task names for consolidating settings stores into one Postgres-backed store.
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
    case Application.get_env(:harness, :landing_settings, root: @default_root) do
      false -> nil
      nil -> nil
      opts when is_list(opts) -> opts |> Keyword.get(:root, @default_root) |> Path.expand()
    end
  end
end
