defmodule Harness.Project do
  @moduledoc """
  A registered orchestration target: source repo, check-command hint, roadmap,
  optional per-project concurrency cap, and optional reviewer pin.

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
  - `language` — optional target-language atom used to select injected agent
    rule sections. `nil` defaults to Elixir-compatible rules; non-Elixir atoms
    suppress Elixir-specific guidance.
  - `roadmap_path` — project root holding `roadmap/tasks.toml` for rmap ingestion.
  - `concurrency_cap` — per-project batch cap; `nil` inherits the global default.
  - `pollution_allowlist` — optional path patterns ignored by the main-checkout
    pollution diff (`Harness.Worktree.Isolation`); `nil` inherits app defaults.
  - `warm_paths` — repo-relative gitignored directories to seed into fresh
    worktrees in addition to the default warm paths.
  - `landing_policy` — `:manual` by default; `:auto` means reviewer-approved
    runs are eligible for autonomous landing.
  - `target_branch` — the branch the autonomous lander fast-forward-pushes an
    approved run onto (e.g. `"development"`). `nil` by default; a project only
    auto-lands when it sets both `landing_policy: :auto` and a `target_branch`.
  - `reviewer` — optional agent atom that pins this project's cross-family
    reviewer gate; `nil` keeps the default auto-selection.
  """

  alias Harness.Project.Source.Github
  alias Harness.Project.Source.Local

  @enforce_keys [:name, :source, :roadmap_path]
  defstruct [
    :name,
    :source,
    :roadmap_path,
    check_command: nil,
    language: nil,
    concurrency_cap: nil,
    pollution_allowlist: nil,
    warm_paths: [],
    landing_policy: :manual,
    target_branch: nil,
    reviewer: nil
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
          language: atom() | nil,
          concurrency_cap: pos_integer() | nil,
          pollution_allowlist: [String.t()] | nil,
          warm_paths: [String.t()],
          landing_policy: landing_policy(),
          target_branch: String.t() | nil,
          reviewer: atom() | nil
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

  @doc """
  Resolves the on-disk repo path for a `{:local, _}` project, or signals that a
  `{:github, _}` source has no operable local checkout for git-mutating callers.

  The post-merge lander and audit both gate on this: a local source yields
  `{:ok, path}` for the rebase/audit worktree; a GitHub source short-circuits
  their `with` chain via `{:skipped, :github_source}` (those flows operate on an
  operator checkout, not the read-only clone cache).
  """
  @spec local_repo_path(t()) :: {:ok, String.t()} | {:skipped, :github_source}
  def local_repo_path(%__MODULE__{source: {:local, _}} = project), do: {:ok, repo_path(project)}
  def local_repo_path(%__MODULE__{source: {:github, _}}), do: {:skipped, :github_source}
end
