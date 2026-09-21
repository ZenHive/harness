defmodule Harness.Worktree.Reclaim do
  @moduledoc """
  Conservative maintenance for leftover `harness/<run-id>` branches and
  filesystem worktree orphans.

  Dry-run by default. Apply deletes a leftover only when the run's commits are
  reachable from the project's configured target. Live, retained, held, failed,
  and unlanded sole copies are left untouched.

  Filesystem orphans that git cannot see (`git worktree list` / `prune`) are
  classified separately: a `.git` back-link that names a moved main checkout is
  offered as git-native `repair` unless the data is already on the target (then
  it is safe to remove). Directories with no git registration are the same
  reachability choice, never a repair.

  Inspection coverage is part of the report: `inspected`, `skipped`, and
  `errors` name what was (not) scanned. An empty leftover list with
  `complete?: true` is a finished scan; registry, repository, target, or Git
  enumeration failures set `complete?: false`. Apply refuses that incomplete
  selected inspection before any deletion or repair.
  """

  alias Harness.Git
  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Harness.Worktree

  require Logger

  @typedoc "What maintenance will do with one leftover."
  @type action :: :reclaim | :repair | :retain

  @typedoc "One planned leftover: a run branch, a worktree dir, or both."
  @type item :: %{
          :action => action(),
          :reason => atom(),
          optional(:kind) => :run | :orphan_dir,
          optional(:run_id) => String.t(),
          optional(:project) => String.t(),
          optional(:branch) => String.t(),
          optional(:path) => String.t(),
          optional(:backlink) => String.t(),
          optional(:repo) => String.t(),
          optional(:target) => String.t(),
          optional(:base_dir) => String.t()
        }

  @typedoc "A selected project that Git enumeration completed for."
  @type inspected :: %{project: String.t(), repo: String.t(), target: String.t()}

  @typedoc "A selected project omitted by design (no operable local checkout)."
  @type skipped :: %{project: String.t(), reason: term()}

  @typedoc "Why a selected project or the registry was not inspected."
  @type inspection_error :: %{
          :scope => :registry | :repository | :target | :git,
          :reason => term(),
          optional(:project) => String.t(),
          optional(:repo) => String.t()
        }

  @typedoc "Dry-run or applied maintenance report."
  @type report :: %{
          dry_run: boolean(),
          complete?: boolean(),
          inspected: [inspected()],
          skipped: [skipped()],
          items: [item()],
          applied: [item()],
          errors: [inspection_error() | {item(), term()}]
        }

  @doc """
  Plans (and optionally applies) reclaim of landed run leftovers.

  Options:

    * `:dry_run` — default `true`. When `false`, performs reclaim/repair.
    * `:base_dir` — worktree root to scan. Default `Worktree.base_dir/0`.
    * `:projects` — `%Harness.Project{}` list. Default `ProjectRegistry.list/0`.

  Apply returns `{:error, {:incomplete_inspection, report}}` when the selected
  inspection did not finish; `applied` stays empty and no deletion or repair
  runs. Dry-run still returns `{:ok, report}` so the operator can read
  coverage and raw error context.
  """
  @spec run(keyword()) :: {:ok, report()} | {:error, {:incomplete_inspection, report()}}
  def run(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, true)
    base_dir = Keyword.get(opts, :base_dir, Worktree.base_dir())
    {contexts, inspected, skipped, inspection_errors} = inspect_selection(base_dir, selected_projects(opts))
    items = plan_items(base_dir, contexts)
    complete? = inspection_errors == []

    report = %{
      dry_run: dry_run?,
      complete?: complete?,
      inspected: inspected,
      skipped: skipped,
      items: items,
      applied: [],
      errors: inspection_errors
    }

    cond do
      dry_run? ->
        {:ok, report}

      not complete? ->
        {:error, {:incomplete_inspection, report}}

      true ->
        {applied, apply_errors} = apply_items(items)
        {:ok, %{report | applied: applied, errors: inspection_errors ++ apply_errors}}
    end
  end

  @spec selected_projects(keyword()) :: {:ok, [Project.t()]} | {:error, :registry_unavailable}
  defp selected_projects(opts) do
    case Keyword.fetch(opts, :projects) do
      {:ok, projects} -> {:ok, projects}
      :error -> default_projects()
    end
  end

  @spec default_projects() :: {:ok, [Project.t()]} | {:error, :registry_unavailable}
  defp default_projects do
    case Process.whereis(ProjectRegistry) do
      nil -> {:error, :registry_unavailable}
      _pid -> {:ok, ProjectRegistry.list()}
    end
  end

  @spec inspect_selection(String.t(), {:ok, [Project.t()]} | {:error, :registry_unavailable}) ::
          {[map()], [inspected()], [skipped()], [inspection_error()]}
  defp inspect_selection(_base_dir, {:error, :registry_unavailable}) do
    {[], [], [], [inspection_error(:registry, nil, nil, :registry_unavailable)]}
  end

  defp inspect_selection(base_dir, {:ok, projects}) do
    projects
    |> Enum.map(&inspect_project(&1, base_dir))
    |> partition_inspection()
  end

  @spec inspect_project(Project.t(), String.t()) :: {:ok, map()} | {:skip, skipped()} | {:error, inspection_error()}
  defp inspect_project(%Project{} = project, base_dir) do
    case Project.local_repo_path(project) do
      {:skipped, :github_source} -> {:skip, %{project: project.name, reason: :github_source}}
      {:ok, repo} -> inspect_local(project, repo, base_dir)
    end
  end

  @spec inspect_local(Project.t(), String.t(), String.t()) :: {:ok, map()} | {:error, inspection_error()}
  defp inspect_local(project, repo, base_dir) do
    with :ok <- require_repo_dir(project, repo),
         {:ok, target} <- require_target(project, repo),
         {:ok, branches} <- require_branches(project, repo),
         :ok <- require_target_ref(project, repo, target) do
      {:ok, %{project: project.name, repo: repo, target: target, base_dir: base_dir, branches: branches}}
    end
  end

  @spec require_repo_dir(Project.t(), String.t()) :: :ok | {:error, inspection_error()}
  defp require_repo_dir(project, repo) do
    case File.stat(repo) do
      {:ok, %{type: :directory}} ->
        :ok

      {:ok, %{type: type}} ->
        {:error, inspection_error(:repository, project.name, repo, {:not_a_directory, type})}

      {:error, reason} ->
        {:error, inspection_error(:repository, project.name, repo, reason)}
    end
  end

  @spec require_target(Project.t(), String.t()) :: {:ok, String.t()} | {:error, inspection_error()}
  defp require_target(project, repo) do
    case Project.target_branch(project) do
      {:ok, target} -> {:ok, target}
      {:skipped, :no_target_branch} -> {:error, inspection_error(:target, project.name, repo, :no_target_branch)}
    end
  end

  @spec require_target_ref(Project.t(), String.t(), String.t()) :: :ok | {:error, inspection_error()}
  defp require_target_ref(project, repo, target) do
    results =
      Enum.map(["refs/remotes/origin/" <> target, "refs/heads/" <> target], fn ref ->
        Git.run(["rev-parse", "--verify", ref <> "^{commit}"], repo)
      end)

    if Enum.any?(results, &match?({:ok, _}, &1)) do
      :ok
    else
      reasons = Enum.map(results, fn {:error, reason} -> reason end)
      {:error, inspection_error(:target, project.name, repo, {:unresolved_target, target, reasons})}
    end
  end

  @spec require_branches(Project.t(), String.t()) :: {:ok, [String.t()]} | {:error, inspection_error()}
  defp require_branches(project, repo) do
    case Git.run(["for-each-ref", "--format=%(refname:short)", "refs/heads/harness/"], repo) do
      {:ok, output} -> {:ok, String.split(output, "\n", trim: true)}
      {:error, reason} -> {:error, inspection_error(:git, project.name, repo, reason)}
    end
  end

  @spec inspection_error(atom(), String.t() | nil, String.t() | nil, term()) :: inspection_error()
  defp inspection_error(scope, project, repo, reason) do
    %{scope: scope, reason: reason}
    |> put_present(:project, project)
    |> put_present(:repo, repo)
  end

  @spec put_present(map(), atom(), term()) :: map()
  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  @spec partition_inspection([{:ok, map()} | {:skip, skipped()} | {:error, inspection_error()}]) ::
          {[map()], [inspected()], [skipped()], [inspection_error()]}
  defp partition_inspection(results) do
    {ctxs, inspected, skipped, errors} =
      Enum.reduce(results, {[], [], [], []}, &accumulate_inspection/2)

    {Enum.reverse(ctxs), Enum.reverse(inspected), Enum.reverse(skipped), Enum.reverse(errors)}
  end

  @spec accumulate_inspection(
          {:ok, map()} | {:skip, skipped()} | {:error, inspection_error()},
          {[map()], [inspected()], [skipped()], [inspection_error()]}
        ) :: {[map()], [inspected()], [skipped()], [inspection_error()]}
  defp accumulate_inspection({:ok, ctx}, {ctxs, inspected, skipped, errors}) do
    {[ctx | ctxs], [inspected_fact(ctx) | inspected], skipped, errors}
  end

  defp accumulate_inspection({:skip, fact}, {ctxs, inspected, skipped, errors}) do
    {ctxs, inspected, [fact | skipped], errors}
  end

  defp accumulate_inspection({:error, error}, {ctxs, inspected, skipped, errors}) do
    {ctxs, inspected, skipped, [error | errors]}
  end

  @spec inspected_fact(map()) :: inspected()
  defp inspected_fact(ctx), do: %{project: ctx.project, repo: ctx.repo, target: ctx.target}

  @spec plan_items(String.t(), [map()]) :: [item()]
  defp plan_items(base_dir, contexts) do
    branch_items = Enum.flat_map(contexts, &branch_items/1)
    dir_items = orphan_dir_items(base_dir, contexts)
    merge_items(branch_items, dir_items)
  end

  @spec branch_items(map()) :: [item()]
  defp branch_items(%{project: name, repo: repo, target: target, base_dir: base_dir, branches: branches}) do
    Enum.map(branches, fn branch ->
      run_id = String.replace_prefix(branch, "harness/", "")
      path = Worktree.run_dir(name, run_id, base_dir: base_dir)
      classify_run(repo, target, name, run_id, branch, path, base_dir)
    end)
  end

  @spec orphan_dir_items(String.t(), [map()]) :: [item()]
  defp orphan_dir_items(base_dir, contexts) do
    by_name = Map.new(contexts, &{&1.project, &1})

    base_dir
    |> filesystem_run_dirs()
    |> Enum.map(&classify_dir(&1, base_dir, by_name))
    |> Enum.reject(&is_nil/1)
  end

  @spec filesystem_run_dirs(String.t()) :: [String.t()]
  defp filesystem_run_dirs(base_dir) do
    [base_dir, "*", "*"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.reject(&landing_container?/1)
  end

  @spec landing_container?(String.t()) :: boolean()
  defp landing_container?(path), do: Path.basename(path) == "landing"

  @spec classify_dir(String.t(), String.t(), map()) :: item() | nil
  defp classify_dir(path, base_dir, by_name) do
    case relative_run(path, base_dir) do
      {project, run_id} ->
        ctx = Map.get(by_name, project)
        branch = Worktree.run_branch(run_id)
        classify_orphan(path, project, run_id, branch, ctx)

      :error ->
        nil
    end
  end

  @spec relative_run(String.t(), String.t()) :: {String.t(), String.t()} | :error
  defp relative_run(path, base_dir) do
    case Path.split(Path.relative_to(path, base_dir)) do
      [project, run_id] -> {project, run_id}
      _other -> :error
    end
  end

  @spec classify_run(String.t(), String.t(), String.t(), String.t(), String.t(), String.t(), String.t()) :: item()
  defp classify_run(repo, target, project, run_id, branch, path, base_dir) do
    base = %{
      kind: :run,
      project: project,
      run_id: run_id,
      branch: branch,
      repo: repo,
      target: target,
      base_dir: base_dir
    }

    base = if File.dir?(path), do: Map.put(base, :path, path), else: base
    Map.merge(base, run_action(repo, target, run_id, path))
  end

  @spec classify_orphan(String.t(), String.t(), String.t(), String.t(), map() | nil) :: item()
  defp classify_orphan(path, project, run_id, branch, ctx) do
    backlink = gitdir_link(path)

    base = %{
      kind: :orphan_dir,
      project: project,
      run_id: run_id,
      branch: branch,
      path: path
    }

    base = maybe_put_context(base, ctx)
    base = maybe_put_backlink(base, backlink)
    Map.merge(base, orphan_action(path, run_id, backlink, ctx))
  end

  @spec maybe_put_context(map(), map() | nil) :: map()
  defp maybe_put_context(item, %{repo: repo, target: target, base_dir: base_dir}) do
    item
    |> Map.put(:repo, repo)
    |> Map.put(:target, target)
    |> Map.put(:base_dir, base_dir)
  end

  defp maybe_put_context(item, _missing), do: item

  @spec run_action(String.t(), String.t(), String.t(), String.t()) :: %{action: action(), reason: atom()}
  defp run_action(repo, target, run_id, path) do
    cond do
      Worktree.live_run?(run_id) -> %{action: :retain, reason: :live_run}
      File.dir?(path) and Worktree.retained?(path) -> %{action: :retain, reason: :retained}
      File.dir?(path) and Worktree.active?(path) -> %{action: :retain, reason: :live_run}
      reachable?(repo, run_id, target) -> %{action: :reclaim, reason: :reachable}
      true -> %{action: :retain, reason: :sole_copy}
    end
  end

  @spec orphan_action(String.t(), String.t(), String.t() | nil, map() | nil) :: %{
          action: action(),
          reason: atom()
        }
  defp orphan_action(path, run_id, backlink, %{repo: repo, target: target}) do
    cond do
      Worktree.live_run?(run_id) -> %{action: :retain, reason: :live_run}
      Worktree.retained?(path) -> %{action: :retain, reason: :retained}
      Worktree.active?(path) -> %{action: :retain, reason: :live_run}
      reachable?(repo, run_id, target) -> %{action: :reclaim, reason: :reachable}
      repairable?(backlink, repo, run_id) -> %{action: :repair, reason: :stale_backlink}
      true -> %{action: :retain, reason: orphan_retain_reason(backlink)}
    end
  end

  defp orphan_action(path, run_id, backlink, nil) do
    cond do
      Worktree.live_run?(run_id) -> %{action: :retain, reason: :live_run}
      Worktree.retained?(path) -> %{action: :retain, reason: :retained}
      is_binary(backlink) -> %{action: :retain, reason: :stale_backlink}
      true -> %{action: :retain, reason: :unregistered}
    end
  end

  @spec orphan_retain_reason(String.t() | nil) :: atom()
  defp orphan_retain_reason(backlink) when is_binary(backlink), do: :stale_backlink
  defp orphan_retain_reason(_missing), do: :unregistered

  @spec maybe_put_backlink(map(), String.t() | nil) :: map()
  defp maybe_put_backlink(item, backlink) when is_binary(backlink), do: Map.put(item, :backlink, backlink)
  defp maybe_put_backlink(item, _missing), do: item

  @spec reachable?(String.t(), String.t(), String.t()) :: boolean()
  defp reachable?(repo, run_id, target) do
    branch = Worktree.run_branch(run_id)

    Git.ancestor?(repo, branch, "refs/remotes/origin/" <> target) or
      Git.ancestor?(repo, branch, "refs/heads/" <> target)
  end

  @spec gitdir_link(String.t()) :: String.t() | nil
  # `.git` is a gitlink file under a harness worktree path, not external input.
  # sobelow_skip ["Traversal.FileModule"]
  defp gitdir_link(dir) do
    case File.read(Path.join(dir, ".git")) do
      {:ok, contents} ->
        case String.trim(contents) do
          "gitdir: " <> gitdir -> gitdir
          _other -> nil
        end

      {:error, _reason} ->
        nil
    end
  end

  @spec repairable?(String.t() | nil, String.t(), String.t()) :: boolean()
  defp repairable?(gitdir, repo, run_id) when is_binary(gitdir) do
    not File.exists?(gitdir) and File.dir?(Path.join([repo, ".git", "worktrees", worktree_admin_id(gitdir, run_id)]))
  end

  defp repairable?(_missing, _repo, _run_id), do: false

  @spec worktree_admin_id(String.t(), String.t()) :: String.t()
  defp worktree_admin_id(gitdir, run_id) do
    case Path.basename(gitdir) do
      "" -> run_id
      id -> id
    end
  end

  @spec merge_items([item()], [item()]) :: [item()]
  defp merge_items(branch_items, dir_items) do
    keyed = Map.new(branch_items, &{item_key(&1), &1})

    dir_items
    |> Enum.reduce(keyed, fn dir_item, acc ->
      key = item_key(dir_item)

      case Map.get(acc, key) do
        nil -> Map.put(acc, key, dir_item)
        run_item -> Map.put(acc, key, overlay_dir(run_item, dir_item))
      end
    end)
    |> Map.values()
    |> Enum.sort_by(&{&1[:project], &1[:run_id], &1[:path]})
  end

  @spec item_key(item()) :: {String.t() | nil, String.t() | nil}
  defp item_key(item), do: {item[:project], item[:run_id]}

  @spec overlay_dir(item(), item()) :: item()
  defp overlay_dir(run_item, dir_item) do
    run_item
    |> Map.put(:path, dir_item.path)
    |> maybe_put_backlink(dir_item[:backlink])
    |> overlay_action(dir_item)
  end

  @spec overlay_action(item(), item()) :: item()
  defp overlay_action(%{reason: :live_run} = run_item, _dir_item), do: run_item
  defp overlay_action(%{reason: :retained} = run_item, _dir_item), do: run_item
  defp overlay_action(%{action: :reclaim} = run_item, _dir_item), do: run_item

  defp overlay_action(run_item, %{action: :repair, reason: reason}) do
    run_item
    |> Map.put(:action, :repair)
    |> Map.put(:reason, reason)
  end

  defp overlay_action(run_item, _dir_item), do: run_item

  @spec apply_items([item()]) :: {[item()], [term()]}
  defp apply_items(items) do
    Enum.reduce(items, {[], []}, fn item, {applied, errors} ->
      case apply_item(item) do
        :ok -> {[item | applied], errors}
        :skip -> {applied, errors}
        {:error, reason} -> {applied, [{item, reason} | errors]}
      end
    end)
  end

  @spec apply_item(item()) :: :ok | :skip | {:error, term()}
  defp apply_item(%{action: :retain}), do: :skip

  defp apply_item(%{action: :reclaim, repo: repo, run_id: run_id, target: target} = item) do
    Worktree.cleanup_landed_run(repo, run_id, target, base_dir: item[:base_dir], path: item[:path])
  end

  defp apply_item(%{action: :repair, repo: repo, path: path}) when is_binary(path) do
    repair_worktree(repo, path)
  end

  defp apply_item(%{action: :repair} = item), do: {:error, {:repair_missing_path, item}}
  defp apply_item(%{action: :reclaim} = item), do: {:error, {:reclaim_missing_repo, item}}

  @spec repair_worktree(String.t(), String.t()) :: :ok | {:error, term()}
  defp repair_worktree(repo, path) do
    case Git.run(["worktree", "repair", path], repo) do
      {:ok, _output} ->
        Logger.info("harness worktree reclaim: repaired #{path}")
        :ok

      {:error, reason} ->
        Logger.warning("harness worktree reclaim: repair failed for #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
