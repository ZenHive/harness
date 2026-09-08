defmodule Harness.ProjectCache.Artifacts do
  @moduledoc false

  alias Harness.Git
  alias Harness.ProjectCache.Command
  alias Harness.Worktree

  @doc false
  @spec validate_outputs(String.t(), [String.t()]) :: :ok | {:error, term()}
  def validate_outputs(source, paths) do
    case Git.run(["ls-files", "-z", "--" | paths], source) do
      {:ok, ""} -> :ok
      {:ok, _tracked} -> {:error, :tracked_cache_output}
      {:error, _} = error -> error
    end
  end

  @doc false
  @spec ignored_outputs(String.t(), [String.t()]) :: :ok | {:error, term()}
  def ignored_outputs(source, paths) do
    each(paths, fn path ->
      case Git.run(["check-ignore", "--quiet", "--", path], source) do
        {:ok, _} -> :ok
        {:error, {:git_failed, _args, 1, _output}} -> {:error, {:cache_output_not_ignored, path}}
        {:error, _} = error -> error
      end
    end)
  end

  @doc false
  @spec publishable(String.t(), [String.t()]) :: :ok | {:error, term()}
  def publishable(source, paths) do
    each(paths, fn path -> walk(Path.join(source, path), source, paths) end)
  end

  @doc false
  # Paths originate in the validated recipe and owned cache/worktree roots.
  # sobelow_skip ["Traversal.FileModule"]
  @spec pack(String.t(), String.t(), [String.t()]) :: :ok | {:error, term()}
  def pack(source, target, paths) do
    with :ok <- File.mkdir_p(target) do
      each(paths, fn path -> copy(Path.join(source, path), Path.join(target, path)) end)
    end
  end

  @doc false
  # Paths originate in the validated recipe and owned cache/worktree roots.
  # sobelow_skip ["Traversal.FileModule"]
  @spec seed(String.t(), String.t(), map(), reference(), integer()) :: {:ok, [String.t()]} | {:error, term()}
  def seed(source, target, recipe, owner, deadline) do
    paths = Enum.reject(recipe["paths"], &match?({:ok, _}, File.lstat(Path.join(target, &1))))
    stage = Path.join(target, ".harness/cache-seed-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false))

    try do
      with :ok <- each(paths, &safe_parents(target, Path.dirname(&1))),
           :ok <- safe_parents(target, ".harness"),
           :ok <- pack(source, stage, paths),
           :ok <- restore(source, stage, target, recipe, paths, owner, deadline),
           :ok <- publishable(stage, paths),
           :ok <- Command.check(owner, deadline) do
        install(stage, target, paths)
      end
    after
      File.rm_rf(stage)
    end
  end

  # Paths originate in the validated recipe and owned cache/worktree roots.
  # sobelow_skip ["Traversal.FileModule"]
  @spec restore(String.t(), String.t(), String.t(), map(), [String.t()], reference(), integer()) ::
          :ok | {:error, term()}
  defp restore(_source, _stage, _target, _recipe, [], _owner, _deadline), do: :ok

  defp restore(source, stage, target, recipe, _paths, owner, deadline) do
    with {:ok, %{"source" => original}} <- manifest(source) do
      env = Map.merge(recipe["env"], %{"HARNESS_CACHE_SOURCE" => original, "HARNESS_CACHE_TARGET" => target})

      case Command.run_all(recipe["restore_commands"], stage, env, owner, deadline) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, {:cache_restore, reason}}
      end
    end
  end

  @doc false
  # Read only the marker inside the owned generation directory.
  # sobelow_skip ["Traversal.FileModule"]
  @spec manifest(String.t()) :: {:ok, map()} | {:error, term()}
  def manifest(source) do
    with {:ok, json} <- File.read(Path.join(source, "complete.json")),
         {:ok, %{"source" => original, "exit_status" => 0} = manifest} when is_binary(original) <- Jason.decode(json) do
      {:ok, manifest}
    else
      other -> {:error, {:cache_manifest, other}}
    end
  end

  @spec install(String.t(), String.t(), [String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  defp install(stage, target, paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, installed} ->
      destination = Path.join(target, path)

      case install_one(stage, target, path, destination) do
        :copied -> {:cont, {:ok, installed ++ [path]}}
        :existing -> {:cont, {:ok, installed}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # Paths originate in the validated recipe and owned cache/worktree roots.
  # sobelow_skip ["Traversal.FileModule"]
  @spec install_one(String.t(), String.t(), String.t(), String.t()) :: :copied | :existing | {:error, term()}
  defp install_one(stage, target, path, destination) do
    case File.lstat(destination) do
      {:ok, _} ->
        :existing

      {:error, :enoent} ->
        with :ok <- safe_parents(target, Path.dirname(path)),
             :ok <- File.mkdir_p(Path.dirname(destination)),
             :ok <- File.rename(Path.join(stage, path), destination),
             do: :copied

      {:error, _} = error ->
        error
    end
  end

  @spec safe_parents(String.t(), String.t()) :: :ok | {:error, term()}
  defp safe_parents(_root, "."), do: :ok

  defp safe_parents(root, relative) do
    with :ok <- safe_parents(root, Path.dirname(relative)) do
      case File.lstat(Path.join(root, relative)) do
        {:ok, %{type: :directory}} -> :ok
        {:error, :enoent} -> :ok
        {:ok, _} -> {:error, {:unsafe_cache_parent, relative}}
        {:error, _} = error -> error
      end
    end
  end

  @spec walk(String.t(), String.t(), [String.t()]) :: :ok | {:error, term()}
  defp walk(path, source, paths) do
    with :ok <- safe_parents(source, Path.relative_to(Path.dirname(path), source)),
         {:ok, stat} <- File.lstat(path) do
      walk_type(stat.type, path, source, paths)
    end
  end

  @spec walk_type(atom(), String.t(), String.t(), [String.t()]) :: :ok | {:error, term()}
  defp walk_type(:regular, _path, _source, _paths), do: :ok

  defp walk_type(:directory, path, source, paths) do
    with {:ok, entries} <- File.ls(path) do
      each(entries, &walk(Path.join(path, &1), source, paths))
    end
  end

  defp walk_type(:symlink, path, source, _paths) do
    with {:ok, link} <- File.read_link(path) do
      with :relative <- Path.type(link),
           {:ok, resolved} <- resolve_link(Path.split(link), Path.dirname(path), 40),
           true <- inside?(resolved, source) do
        :ok
      else
        _ -> {:error, {:external_cache_symlink, Path.relative_to(path, source)}}
      end
    end
  end

  defp walk_type(type, _path, _source, _paths), do: {:error, {:unsupported_cache_artifact, type}}

  @spec resolve_link([String.t()], String.t(), non_neg_integer()) :: {:ok, String.t()} | {:error, term()}
  defp resolve_link([], current, _budget), do: {:ok, current}
  defp resolve_link(_parts, _current, 0), do: {:error, :symlink_loop}
  defp resolve_link([".." | rest], current, budget), do: resolve_link(rest, Path.dirname(current), budget)
  defp resolve_link(["." | rest], current, budget), do: resolve_link(rest, current, budget)

  defp resolve_link([part | rest], current, budget) do
    path = Path.join(current, part)

    case File.read_link(path) do
      {:ok, link} ->
        if Path.type(link) == :relative,
          do: resolve_link(Path.split(link) ++ rest, current, budget - 1),
          else: {:error, :absolute_symlink}

      {:error, reason} when reason in [:einval, :enoent] ->
        resolve_link(rest, path, budget)

      {:error, _} = error ->
        error
    end
  end

  @spec inside?(String.t(), String.t()) :: boolean()
  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  # Paths originate in the validated recipe and owned cache/worktree roots.
  # sobelow_skip ["Traversal.FileModule"]
  @spec copy(String.t(), String.t()) :: :ok | {:error, term()}
  defp copy(source, target) do
    with :ok <- File.mkdir_p(Path.dirname(target)) do
      Worktree.clone_copy(source, target, Worktree.clone_copy_flag(:os.type()))
    end
  end

  @spec each(list(), (term() -> :ok | {:error, term()})) :: :ok | {:error, term()}
  defp each(values, fun) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case fun.(value) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end
