defmodule Harness.Project.Source.Github do
  @moduledoc """
  The GitHub-URL variant of `t:Harness.Project.source/0`.

  Represented on the project struct as the tagged tuple `{:github, url}`. The
  first time a GitHub-source project is asked for its local repo, harness
  clones `url` to `<cache_root>/<project.name>`. On every subsequent request,
  harness `git fetch`es the cached clone and fast-forwards its default branch,
  so a run never grades against a stale `main`. If the cache directory was
  deleted between runs, the next call transparently re-clones rather than
  failing.

  Credentials piggyback on the host's existing `gh` CLI and SSH config — if a
  shell `git clone` of the URL succeeds for the user, harness's `System.cmd`
  shell-out will too. No auth layer lives inside harness.

  ## Cache root

  The cache root is resolved per call in this order:

    1. The `:cache_root` keyword option passed to `local_path/2` /
       `ensure_local/2`.
    2. `Application.get_env(:harness, :project)[:cache_root]`.
    3. The built-in default `~/_DATA/harness/projects`.
  """

  alias Harness.Git
  alias Harness.Project

  @default_cache_root "~/_DATA/harness/projects"
  @allowed_url_schemes ~w(http https ssh git)
  @scp_url_pattern ~r/\Agit@[^:\s]+:[^\s]+\z/

  @typedoc "The tagged tuple form stored on `%Harness.Project{}.source`."
  @type t :: {:github, url :: String.t()}

  @typedoc "Why a clone/fetch attempt failed."
  @type error ::
          {:clone_failed, status :: integer(), output :: String.t()}
          | {:fetch_failed, term()}
          | {:default_branch_lookup_failed, term()}
          | {:fast_forward_failed, term()}
          | {:invalid_url, :leading_dash | :unsupported_scheme}
          | {:mkdir_failed, String.t(), File.posix()}

  @doc "Returns the upstream GitHub URL for a `{:github, _}` project."
  @spec url(Project.t()) :: String.t()
  def url(%Project{source: {:github, url}}) when is_binary(url), do: url

  @doc """
  Returns the local cache path for `project` — `<cache_root>/<project.name>`.

  Pure: does not touch the filesystem. Use `ensure_local/2` to also clone or
  fetch.
  """
  @spec local_path(Project.t(), keyword()) :: String.t()
  def local_path(%Project{name: name}, opts \\ []), do: Path.join(cache_root(opts), name)

  @doc """
  Ensures a fresh local clone of `project` and returns its path.

    * If the cache dir does not exist (or is not a git repo), clones `url` into
      `<cache_root>/<project.name>`.
    * If it already is a git repo, `git fetch`es and fast-forwards the default
      branch to its upstream.
    * If a previously cloned cache dir was removed between runs, this path is
      identical to the first-clone case — it re-clones transparently.

  Returns `{:ok, path}` on success or `{:error, reason}` — see `t:error/0`.
  """
  @spec ensure_local(Project.t(), keyword()) :: {:ok, String.t()} | {:error, error()}
  def ensure_local(%Project{} = project, opts \\ []) do
    path = local_path(project, opts)

    if git_repo?(path) do
      with {:ok, _} <- fetch(path),
           {:ok, _} <- fast_forward_default_branch(path) do
        {:ok, path}
      end
    else
      clone(url(project), path)
    end
  end

  @spec cache_root(keyword()) :: String.t()
  defp cache_root(opts) do
    configured =
      Keyword.get(opts, :cache_root) ||
        :harness |> Application.get_env(:project, []) |> Keyword.get(:cache_root)

    Path.expand(configured || @default_cache_root)
  end

  @spec git_repo?(String.t()) :: boolean()
  defp git_repo?(path), do: File.dir?(Path.join(path, ".git"))

  @spec clone(String.t(), String.t()) :: {:ok, String.t()} | {:error, error()}
  defp clone(url, path) do
    with :ok <- validate_clone_url(url) do
      clone_validated(url, path)
    end
  end

  @spec validate_clone_url(String.t()) :: :ok | {:error, error()}
  defp validate_clone_url("-" <> _rest), do: {:error, {:invalid_url, :leading_dash}}

  defp validate_clone_url(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme}} when is_binary(scheme) ->
        if String.downcase(scheme) in @allowed_url_schemes,
          do: :ok,
          else: {:error, {:invalid_url, :unsupported_scheme}}

      _without_allowed_scheme ->
        if Regex.match?(@scp_url_pattern, url),
          do: :ok,
          else: {:error, {:invalid_url, :unsupported_scheme}}
    end
  end

  @spec clone_validated(String.t(), String.t()) :: {:ok, String.t()} | {:error, error()}
  # `path` and its parent are harness-owned cache directories under
  # `cache_root`, not user input — the project name is validated upstream by
  # `Harness.ProjectRegistry`.
  # sobelow_skip ["Traversal.FileModule"]
  defp clone_validated(url, path) do
    parent = Path.dirname(path)

    case File.mkdir_p(parent) do
      :ok ->
        case System.cmd("git", ["clone", "--quiet", "--", url, path], stderr_to_stdout: true) do
          {_output, 0} -> {:ok, path}
          {output, status} -> {:error, {:clone_failed, status, output}}
        end

      {:error, reason} ->
        {:error, {:mkdir_failed, parent, reason}}
    end
  end

  @spec fetch(String.t()) :: {:ok, String.t()} | {:error, error()}
  defp fetch(path) do
    case Git.run(["fetch", "--prune", "origin"], path) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, {:fetch_failed, reason}}
    end
  end

  # After fetch, refs/remotes/origin/<default> carries the new tip but local
  # refs/heads/<default> is stale. `git worktree add ... HEAD` would carve from
  # the stale local ref, so fast-forward the local branch to its upstream
  # before any worktree is carved off the cache.
  @spec fast_forward_default_branch(String.t()) :: {:ok, String.t()} | {:error, error()}
  defp fast_forward_default_branch(path) do
    with {:ok, branch} <- default_branch(path) do
      case Git.run(["update-ref", "refs/heads/" <> branch, "refs/remotes/origin/" <> branch], path) do
        {:ok, output} -> {:ok, output}
        {:error, reason} -> {:error, {:fast_forward_failed, reason}}
      end
    end
  end

  @spec default_branch(String.t()) :: {:ok, String.t()} | {:error, error()}
  defp default_branch(path) do
    case Git.run(["symbolic-ref", "--short", "HEAD"], path) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, reason} -> {:error, {:default_branch_lookup_failed, reason}}
    end
  end
end
