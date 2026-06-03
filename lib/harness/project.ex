defmodule Harness.Project do
  @moduledoc """
  A registered orchestration target: source repo, check-command hint, roadmap,
  and optional per-project concurrency cap.

  - `name` — unique slug; worktrees are rooted at `<base_dir>/<name>/<run-id>`.
  - `source` — where the repo lives:
      - `{:local, path}` — an already-checked-out working tree on disk.
      - `{:github, url}` — a GitHub URL harness clones (and `git fetch`es
        before each run) into `<cache_root>/<name>`. See
        `Harness.Project.Source.Github`.
  - `check_command` — free-text hint handed to the reviewer AI (e.g.
    `"mix precommit"`, `"cargo test"`). The reviewer runs the project's checks
    itself and judges the result; harness never executes this command — it is
    prompt text, not a verification gate.
  - `roadmap_path` — project root holding `roadmap/tasks.toml` for rmap ingestion.
  - `concurrency_cap` — per-project batch cap; `nil` inherits the global default.
  - `pollution_allowlist` — optional path patterns ignored by the main-checkout
    pollution diff (`Harness.Worktree.Isolation`); `nil` inherits app defaults.
  - `landing_policy` — `:manual` by default; `:auto` means reviewer-approved
    runs are eligible for autonomous landing.
  - `target_branch` — the branch the autonomous lander fast-forward-pushes an
    approved run onto (e.g. `"development"`). `nil` by default; a project only
    auto-lands when it sets both `landing_policy: :auto` and a `target_branch`.
  """

  alias Harness.Project.Source.Github
  alias Harness.Project.Source.Local

  @enforce_keys [:name, :source, :roadmap_path]
  defstruct [
    :name,
    :source,
    :roadmap_path,
    check_command: nil,
    concurrency_cap: nil,
    pollution_allowlist: nil,
    landing_policy: :manual,
    target_branch: nil
  ]

  @typedoc "Where harness finds the target repository."
  @type source :: Local.t() | Github.t()

  @typedoc "Whether approved runs require manual landing or are eligible for auto-land."
  @type landing_policy :: :manual | :auto

  @typedoc "A first-class orchestration target."
  @type t :: %__MODULE__{
          name: String.t(),
          source: source(),
          roadmap_path: String.t(),
          check_command: String.t() | nil,
          concurrency_cap: pos_integer() | nil,
          pollution_allowlist: [String.t()] | nil,
          landing_policy: landing_policy(),
          target_branch: String.t() | nil
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
