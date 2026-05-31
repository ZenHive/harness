defmodule Harness.Project do
  @moduledoc """
  A registered orchestration target: source repo, verification stack, roadmap,
  and optional per-project concurrency cap.

  - `name` — unique slug; worktrees are rooted at `<base_dir>/<name>/<run-id>`.
  - `source` — where the repo lives:
      - `{:local, path}` — an already-checked-out working tree on disk.
      - `{:github, url}` — a GitHub URL harness clones (and `git fetch`es
        before each run) into `<cache_root>/<name>`. See
        `Harness.Project.Source.Github`.
  - `check_stacks` — the list of `%Harness.CheckStack{}`s grading runs against,
    one per language/component. Verification runs every stack in its own
    `workdir` (relative to the worktree root) and aggregates into a single
    verdict (green iff every stack is green). A single-language project is a
    one-element list with `workdir: ""`.
  - `roadmap_path` — project root holding `roadmap/tasks.toml` for rmap ingestion.
  - `concurrency_cap` — per-project batch cap; `nil` inherits the global default.
  - `pollution_allowlist` — optional path patterns ignored by the main-checkout
    pollution diff (`Harness.Worktree.Isolation`); `nil` inherits app defaults.
  - `landing_policy` — `:manual` by default; `:auto` means green runs are
    eligible for autonomous landing.
  - `target_branch` — the branch the autonomous lander fast-forward-pushes an
    approved run onto (e.g. `"development"`). `nil` by default; a project only
    auto-lands when it sets both `landing_policy: :auto` and a `target_branch`.
  - `semantic_gate` — when the cross-family semantic gate (Task 99) runs on a
    green verdict, decoupled from auto-land (Task 123):
      - `:always` — every green run is gated, even under `landing_policy: :manual`
        (lets a manual-landing project — e.g. harness's own dogfooding — opt the
        AC-aware check on).
      - `:auto_land_only` — gated only when the project would auto-land
        (`landing_policy: :auto`). The default; preserves the original
        gate-iff-auto-landing behaviour.
      - `:off` — never gated, even when auto-landing.
    A per-dispatch `semantic_gate: [enabled: true | false]` run opt overrides
    this project-level setting for a single run.
  """

  alias Harness.CheckStack
  alias Harness.Project.Source.Github
  alias Harness.Project.Source.Local

  @enforce_keys [:name, :source, :check_stacks, :roadmap_path]
  defstruct [
    :name,
    :source,
    :check_stacks,
    :roadmap_path,
    concurrency_cap: nil,
    pollution_allowlist: nil,
    landing_policy: :manual,
    target_branch: nil,
    semantic_gate: :auto_land_only
  ]

  @typedoc "Where harness finds the target repository."
  @type source :: Local.t() | Github.t()

  @typedoc "When the cross-family semantic gate runs on a green verdict (Task 123)."
  @type semantic_gate_mode :: :always | :auto_land_only | :off

  @typedoc "A first-class orchestration target."
  @type t :: %__MODULE__{
          name: String.t(),
          source: source(),
          check_stacks: [CheckStack.t()],
          roadmap_path: String.t(),
          concurrency_cap: pos_integer() | nil,
          pollution_allowlist: [String.t()] | nil,
          landing_policy: :manual | :auto,
          target_branch: String.t() | nil,
          semantic_gate: semantic_gate_mode()
        }

  @doc """
  Returns the local repository path for `project`.

  For `{:local, path}` sources this is the expanded path. For `{:github, url}`
  sources this is the cache path `<cache_root>/<project.name>` — it may not
  exist yet; call `ensure_local_repo/2` first to clone or fetch.
  """
  @spec repo_path(t(), keyword()) :: String.t()
  def repo_path(project, opts \\ [])
  def repo_path(%__MODULE__{source: {:local, _}} = project, _opts), do: Local.path(project)

  def repo_path(%__MODULE__{source: {:github, _}} = project, opts), do: Github.local_path(project, opts)

  @doc """
  Ensures `project`'s local repository is present and (for GitHub sources) up
  to date with its upstream default branch.

  For `{:local, _}` sources this is a no-op that returns the expanded path.

  For `{:github, _}` sources this clones on first call, `git fetch`es plus
  fast-forwards the default branch on subsequent calls, and transparently
  re-clones if the cache directory was removed between calls.

  Returns `{:ok, path}` or `{:error, reason}` (see `t:Harness.Project.Source.Github.error/0`).
  """
  @spec ensure_local_repo(t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def ensure_local_repo(project, opts \\ [])

  def ensure_local_repo(%__MODULE__{source: {:local, _}} = project, _opts), do: {:ok, Local.path(project)}

  def ensure_local_repo(%__MODULE__{source: {:github, _}} = project, opts), do: Github.ensure_local(project, opts)
end
