defmodule Harness.ProjectCache do
  @moduledoc """
  Opt-in preparation of immutable project cache generations before agent dispatch.

  A private checkout builds bytes; a host file lock serializes each compatibility
  key, and directory rename publishes only complete artifacts. Neither a cache
  hit nor a successful preparation command is a review verdict. See
  `docs/project-cache.md` for the recipe and compatibility contract.
  """

  alias Harness.Git
  alias Harness.ProjectCache.Artifacts
  alias Harness.ProjectCache.Command
  alias Harness.ProjectCache.Recipe
  alias Harness.Worktree

  require Logger

  @doc "Prepares and seeds configured artifacts, then performs legacy warming."
  @spec warm(Worktree.t(), map() | nil, keyword()) :: :ok
  def warm(worktree, recipe, opts \\ []) do
    case prepare(worktree, recipe, opts) do
      {:ok, report} ->
        Logger.info("harness cache preparation: #{inspect(report)}")

      {:error, reason} ->
        Logger.warning("harness cache preparation failed: #{inspect(reason)}; agent checks still required")

      :disabled ->
        :ok
    end

    excluded = if is_map(recipe), do: Map.get(recipe, "paths", []), else: []
    Worktree.warm(worktree, Keyword.put(opts, :exclude_paths, excluded))
  end

  @doc "Builds/reuses a generation and seeds isolated copies. Reports mechanics only."
  @spec prepare(Worktree.t(), term(), keyword()) :: :disabled | {:ok, map()} | {:error, term()}
  def prepare(worktree, recipe, opts \\ []) do
    case Recipe.normalize(recipe) do
      {:ok, recipe} when is_map(recipe) ->
        run_preparation(worktree, recipe, opts)

      {:ok, nil} ->
        :disabled

      {:error, _} = error ->
        error
    end
  end

  @spec run_preparation(Worktree.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  defp run_preparation(worktree, recipe, opts) do
    caller = self()

    task =
      Task.Supervisor.async_nolink(Harness.Run.TaskSupervisor, fn ->
        owner = Process.monitor(caller)

        Worktree.with_write_lock(worktree.path, fn ->
          execute_owned(caller, worktree, recipe, opts, owner)
        end)
      end)

    Task.await(task, :infinity)
  catch
    :exit, reason -> {:error, {:preparation_crashed, reason}}
  end

  @spec execute_owned(pid(), Worktree.t(), map(), keyword(), reference()) :: {:ok, map()} | {:error, term()}
  defp execute_owned(caller, worktree, recipe, opts, owner) do
    if Process.alive?(caller),
      do: execute(worktree, recipe, opts, owner),
      else: {:error, :interrupted}
  end

  # Root is operator configuration; descendants use a digest and generated stage id.
  # sobelow_skip ["Traversal.FileModule"]
  @spec execute(Worktree.t(), map(), keyword(), reference()) :: {:ok, map()} | {:error, term()}
  defp execute(worktree, recipe, opts, owner) do
    started = System.monotonic_time(:millisecond)
    deadline = started + recipe["timeout_ms"]
    environment = Map.merge(System.get_env(), recipe["env"])
    config = Application.get_env(:harness, :project_cache, [])
    root = Path.expand(Keyword.get(opts, :cache_root, Keyword.get(config, :root, "~/.cache/harness/project-cache")))

    with :ok <- File.mkdir_p(root),
         {:ok, key} <- key(worktree, recipe, environment, owner, deadline) do
      destination = Path.join(root, key)

      seed_generation(worktree, Map.put(recipe, "env", environment), destination, owner, deadline, key, started)
    end
  end

  @spec seed_generation(Worktree.t(), map(), String.t(), reference(), integer(), String.t(), integer()) ::
          {:ok, map()} | {:error, term()}
  defp seed_generation(worktree, recipe, destination, owner, deadline, key, started) do
    with {:ok, state} <-
           Command.locked(destination <> ".lock", owner, deadline, fn ->
             generation(worktree, recipe, destination, owner, deadline)
           end),
         :ok <- Command.check(owner, deadline),
         {:ok, copied} <- Artifacts.seed(destination, worktree.path, recipe, owner, deadline) do
      {:ok, %{key: key, state: state, copied: copied, elapsed_ms: System.monotonic_time(:millisecond) - started}}
    end
  end

  @spec key(Worktree.t(), map(), map(), reference(), integer()) :: {:ok, String.t()} | {:error, term()}
  defp key(worktree, recipe, environment, owner, deadline) do
    with {:ok, inputs} <- Git.run(["ls-tree", "-r", "-z", worktree.base_sha, "--" | recipe["inputs"]], worktree.repo),
         {:ok, tools} <-
           Command.run_all(recipe["identity_commands"], worktree.path, environment, owner, deadline, :digest) do
      identity = {
        1,
        Path.expand(worktree.repo),
        filter_inputs(inputs, recipe["exclude_inputs"]),
        recipe_identity(recipe),
        tools,
        :os.type(),
        :erlang.system_info(:system_architecture),
        identity_env(environment, recipe["env_inputs"])
      }

      {:ok, :sha256 |> :crypto.hash(:erlang.term_to_binary(identity, [:deterministic])) |> Base.encode16(case: :lower)}
    end
  end

  @spec recipe_identity(map()) :: map()
  defp recipe_identity(%{"exclude_inputs" => []} = recipe), do: Map.delete(recipe, "exclude_inputs")
  defp recipe_identity(recipe), do: recipe

  @spec filter_inputs(binary(), [String.t()]) :: binary()
  defp filter_inputs(inputs, []), do: inputs

  defp filter_inputs(inputs, exclusions) do
    inputs
    |> :binary.split(<<0>>, [:global, :trim_all])
    |> Enum.reject(fn entry ->
      [_metadata, path] = :binary.split(entry, "\t")
      Enum.any?(exclusions, &excluded_path?(path, &1))
    end)
    |> Enum.map_join(&(&1 <> <<0>>))
  end

  @spec excluded_path?(binary(), binary()) :: boolean()
  defp excluded_path?(path, exclusion) do
    directory = if String.ends_with?(exclusion, "/"), do: exclusion, else: exclusion <> "/"
    path == exclusion or String.starts_with?(path, directory)
  end

  @spec identity_env(map(), [String.t()] | nil) :: map()
  defp identity_env(environment, nil), do: environment
  defp identity_env(environment, inputs), do: Map.take(environment, inputs)

  @spec generation(Worktree.t(), map(), String.t(), reference(), integer()) :: {:ok, :hit | :built} | {:error, term()}
  defp generation(worktree, recipe, destination, owner, deadline) do
    if File.regular?(Path.join(destination, "complete.json")) do
      with {:ok, _manifest} <- Artifacts.manifest(destination), do: {:ok, :hit}
    else
      build(worktree, recipe, destination, owner, deadline)
    end
  end

  # Paths originate in the validated recipe and owned cache/worktree roots.
  # sobelow_skip ["Traversal.FileModule"]
  @spec build(Worktree.t(), map(), String.t(), reference(), integer()) :: {:ok, :built} | {:error, term()}
  defp build(worktree, recipe, destination, owner, deadline) do
    stage = destination <> ".building-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    source = Path.join(stage, "source")
    artifacts = Path.join(stage, "artifacts")

    started = System.monotonic_time(:millisecond)

    try do
      with :ok <- File.mkdir_p(stage),
           {:ok, _} <- Git.run(["clone", "--shared", "--no-checkout", "--", worktree.repo, source], stage),
           {:ok, _} <- Git.run(["checkout", "--detach", worktree.base_sha], source),
           :ok <- Artifacts.validate_outputs(source, recipe["paths"]),
           {:ok, _outputs} <- Command.run_all(recipe["commands"], source, recipe["env"], owner, deadline),
           :ok <- Artifacts.ignored_outputs(source, recipe["paths"]),
           :ok <- Artifacts.publishable(source, recipe["paths"]),
           :ok <- Artifacts.pack(source, artifacts, recipe["paths"]),
           :ok <-
             File.write(
               Path.join(artifacts, "complete.json"),
               Jason.encode!(%{
                 source: source,
                 commands: length(recipe["commands"]),
                 exit_status: 0,
                 prepared_ms: System.monotonic_time(:millisecond) - started
               })
             ),
           :ok <- Command.check(owner, deadline),
           :ok <- File.rename(artifacts, destination) do
        {:ok, :built}
      end
    after
      File.rm_rf(stage)
    end
  end
end
