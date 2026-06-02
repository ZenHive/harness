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
  - `review_green` — when `true` (the default), even a green verdict gets one
    cross-family reviewer pass scoped to acceptance-criteria conformance before
    the run settles `:done` (Task 162) — no unreviewed code lands. Set `false`
    to opt out: green settles directly on the check stack alone. A per-dispatch
    `review_green: true` run opt forces the pass on for one run. Replaces the
    deprecated `semantic_gate` mode enum — registry load maps legacy configs
    (`:always`/`:auto_land_only` → `true`, `:off` → `false`).
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
    review_green: true
  ]

  @typedoc "Where harness finds the target repository."
  @type source :: Local.t() | Github.t()

  @typedoc "Whether green runs require manual landing or are eligible for auto-land."
  @type landing_policy :: :manual | :auto

  @typedoc "A first-class orchestration target."
  @type t :: %__MODULE__{
          name: String.t(),
          source: source(),
          check_stacks: [CheckStack.t()],
          roadmap_path: String.t(),
          concurrency_cap: pos_integer() | nil,
          pollution_allowlist: [String.t()] | nil,
          landing_policy: landing_policy(),
          target_branch: String.t() | nil,
          review_green: boolean()
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
