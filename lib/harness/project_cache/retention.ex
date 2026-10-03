defmodule Harness.ProjectCache.Retention do
  @moduledoc "Mechanical LRU reclamation of idle project-cache generations."

  alias Harness.Config
  alias Harness.ProjectCache.Command

  require Logger

  @legacy_stage_timeout_ms 1_800_000

  @doc false
  @spec lock_path(String.t()) :: String.t()
  def lock_path(root), do: Path.join(root, ".retention.lock")

  @doc false
  @spec family(String.t(), :outer | :seed) :: String.t()
  def family(repo, kind) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary({Path.expand(repo), kind}))
    |> Base.encode16(case: :lower)
  end

  # sobelow_skip ["Traversal.FileModule"] — destination is a generation path; the sidecar is its sibling.
  @doc "Records use under the generation lock without modifying cached artifacts."
  @spec used(String.t(), String.t()) :: :ok | {:error, term()}
  def used(destination, family) do
    usage = read_usage(destination <> ".usage")
    uses = Map.put(usage, family, System.system_time(:nanosecond))
    temporary = destination <> ".usage.tmp"

    with :ok <- File.write(temporary, Jason.encode!(uses)),
         do: File.rename(temporary, destination <> ".usage")
  rescue
    error in [File.Error, Jason.DecodeError] -> {:error, {:cache_usage, Exception.message(error)}}
  end

  @doc """
  Reclaims idle generations under the root lock.

  `nonblock: true` (the default) returns `{:error, {:lock_exit, 75}}` when a
  preparation holds the shared root lock. Preparation passes `nonblock: false`
  and waits, because it has not taken that shared lock yet.
  """
  @spec reclaim(String.t(), reference(), integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def reclaim(root, owner, deadline, opts \\ []) do
    Command.locked(
      lock_path(root),
      owner,
      deadline,
      fn ->
        sweep(root, owner, deadline, opts)
      end,
      nonblock: Keyword.get(opts, :nonblock, true)
    )
  rescue
    error in [File.Error, Jason.DecodeError] -> {:error, {:cache_retention, Exception.message(error)}}
  end

  @spec sweep(String.t(), reference(), integer(), keyword()) :: {:ok, map()} | {:error, term()}
  defp sweep(root, owner, deadline, opts) do
    now = System.system_time(:nanosecond)
    idle = Keyword.get(opts, :max_idle_ms, Config.get({:project_cache, :max_idle_ms})) * 1_000_000
    cap = Keyword.get(opts, :max_bytes, Config.get({:project_cache, :max_bytes}))

    with :ok <- sweep_stages(root, owner, deadline, div(now, 1_000_000)) do
      entries = generations(root)
      protected = protected(entries)
      total = accounted_total(root, entries)
      reclaim_entries(entries, protected, total, cap, idle, now, owner, deadline)
    end
  end

  @spec reclaim_entries(
          [map()],
          MapSet.t(),
          non_neg_integer(),
          integer(),
          integer(),
          integer(),
          reference(),
          integer()
        ) :: {:ok, map()} | {:error, term()}
  defp reclaim_entries(entries, protected, total, cap, idle, now, owner, deadline) do
    entries
    |> Enum.sort_by(&{&1.last_used, &1.path})
    |> Enum.reduce_while({:ok, total}, fn entry, {:ok, total} ->
      drop_entry(entry, protected, total, cap, idle, now, owner, deadline)
    end)
    |> report_remaining(cap)
  end

  @spec drop_entry(
          map(),
          MapSet.t(),
          non_neg_integer(),
          integer(),
          integer(),
          integer(),
          reference(),
          integer()
        ) :: {:cont, {:ok, non_neg_integer()}} | {:halt, {:error, term()}}
  defp drop_entry(entry, protected, total, cap, idle, now, owner, deadline) do
    if MapSet.member?(protected, entry.path) or not evict?(entry, total, cap, idle, now) do
      {:cont, {:ok, total}}
    else
      delete_entry(entry, total, owner, deadline)
    end
  end

  @spec evict?(map(), non_neg_integer(), integer(), integer(), integer()) :: boolean()
  defp evict?(entry, total, cap, idle, now) do
    now - entry.last_used > idle or total > cap
  end

  @spec delete_entry(map(), non_neg_integer(), reference(), integer()) ::
          {:cont, {:ok, non_neg_integer()}} | {:halt, {:error, term()}}
  defp delete_entry(entry, total, owner, deadline) do
    case remove(entry.path, owner, deadline) do
      :ok -> {:cont, {:ok, total - entry.bytes}}
      {:error, {:lock_exit, 75}} -> {:cont, {:ok, total}}
      {:error, _} = error -> {:halt, error}
    end
  end

  @spec report_remaining({:ok, non_neg_integer()} | {:error, term()}, integer()) :: {:ok, map()} | {:error, term()}
  defp report_remaining({:ok, remaining}, cap), do: {:ok, %{bytes: remaining, over_budget: remaining > cap}}
  defp report_remaining({:error, _} = error, _cap), do: error

  # sobelow_skip ["Traversal.FileModule"] — names come from the cache root and must be 64 hex digits.
  @spec generations(String.t()) :: [map()]
  defp generations(root) do
    root
    |> File.ls!()
    |> Enum.filter(&Regex.match?(~r/\A[0-9a-f]{64}\z/, &1))
    |> Enum.map(&Path.join(root, &1))
    |> Enum.filter(&directory?/1)
    |> Enum.flat_map(&generation_entry/1)
  end

  # sobelow_skip ["Traversal.FileModule"] — path is a generation directory under the cache root.
  @spec generation_entry(String.t()) :: [map()]
  defp generation_entry(path) do
    manifest = read_json(Path.join(path, "complete.json"))
    usage = read_usage(path <> ".usage")
    fallback = File.stat!(path, time: :posix).mtime * 1_000_000_000
    uses = manifest |> manifest_uses(fallback) |> Map.merge(usage)
    last_used = uses |> Map.values() |> Enum.max(fn -> fallback end)

    [
      %{
        path: path,
        uses: uses,
        last_used: last_used,
        bytes: directory_bytes(path) + optional_bytes(path <> ".usage")
      }
    ]
  rescue
    error in [File.Error, Jason.DecodeError] ->
      Logger.warning("harness cache retention skipped #{path}: #{Exception.message(error)}")
      []
  end

  # Published generations are immutable, so the directory size is stable.
  # Later passes read the sibling record instead of walking artifact trees.
  # sobelow_skip ["Traversal.FileModule"] — the size record is the generation path plus `.bytes`.
  @spec directory_bytes(String.t()) :: non_neg_integer()
  defp directory_bytes(path) do
    case File.read(path <> ".bytes") do
      {:ok, data} ->
        case Integer.parse(String.trim(data)) do
          {size, ""} when size >= 0 -> size
          _ -> measure_directory(path)
        end

      {:error, :enoent} ->
        measure_directory(path)

      {:error, reason} ->
        Logger.warning("harness cache retention size read failed: #{inspect(reason)}")
        measure_directory(path)
    end
  end

  # sobelow_skip ["Traversal.FileModule"] — writes only the sibling size record of a generation directory.
  @spec measure_directory(String.t()) :: non_neg_integer()
  defp measure_directory(path) do
    size = bytes(path)
    _ = File.write(path <> ".bytes", Integer.to_string(size))
    size
  end

  # sobelow_skip ["Traversal.FileModule"] — lists only the operator-configured cache root.
  @spec accounted_total(String.t(), [map()]) :: non_neg_integer()
  defp accounted_total(root, entries) do
    paths = MapSet.new(Enum.map(entries, & &1.path))

    extra =
      root
      |> File.ls!()
      |> Enum.map(&Path.join(root, &1))
      |> Enum.reject(&(MapSet.member?(paths, &1) or sidecar?(paths, &1)))
      |> Enum.map(&bytes/1)
      |> Enum.sum()

    extra + Enum.sum(Enum.map(entries, & &1.bytes))
  end

  @spec sidecar?(MapSet.t(), String.t()) :: boolean()
  defp sidecar?(paths, path) do
    Enum.any?(paths, fn entry ->
      path in [entry <> ".usage", entry <> ".usage.tmp", entry <> ".bytes"]
    end)
  end

  @spec manifest_uses(map(), integer()) :: map()
  defp manifest_uses(%{"retention_family" => family}, timestamp) when is_binary(family), do: %{family => timestamp}

  # Shipped legacy manifests have a deleted stage/source path and a command
  # count, neither a repository identity nor a seed/outer discriminator.
  defp manifest_uses(_manifest, _timestamp), do: %{}

  @spec protected([map()]) :: MapSet.t()
  defp protected(entries) do
    entries
    |> Enum.flat_map(fn entry -> Enum.map(entry.uses, fn {family, used} -> {family, used, entry.path} end) end)
    |> Enum.group_by(&elem(&1, 0))
    |> MapSet.new(fn {_family, uses} -> uses |> Enum.max_by(&{elem(&1, 1), elem(&1, 2)}) |> elem(2) end)
  end

  # sobelow_skip ["Traversal.FileModule"] — path is a generation directory; lock files are not removed.
  @spec remove(String.t(), reference(), integer()) :: :ok | {:error, term()}
  defp remove(path, owner, deadline) do
    Command.locked(
      path <> ".lock",
      owner,
      deadline,
      fn ->
        File.rm_rf!(path)
        File.rm_rf!(path <> ".usage")
        File.rm_rf!(path <> ".usage.tmp")
        File.rm_rf!(path <> ".bytes")
        :ok
      end,
      nonblock: true
    )
  end

  # sobelow_skip ["Traversal.FileModule"] — stage names must match `<64-hex>.building-<id>` under the cache root.
  @spec sweep_stages(String.t(), reference(), integer(), integer()) :: :ok | {:error, term()}
  defp sweep_stages(root, owner, deadline, now) do
    root
    |> File.ls!()
    |> Enum.filter(&Regex.match?(~r/\A[0-9a-f]{64}\.building-[A-Za-z0-9_-]+\z/, &1))
    |> Enum.reduce_while(:ok, fn name, :ok ->
      drop_stage(root, name, owner, deadline, now)
    end)
  end

  # sobelow_skip ["Traversal.FileModule"] — stage path is joined from a matched cache-root name.
  @spec drop_stage(String.t(), String.t(), reference(), integer(), integer()) ::
          {:cont, :ok} | {:halt, {:error, term()}}
  defp drop_stage(root, name, owner, deadline, now) do
    path = Path.join(root, name)
    [key, _suffix] = String.split(name, ".building-", parts: 2)

    root
    |> Path.join(key <> ".lock")
    |> Command.locked(owner, deadline, fn -> remove_expired_stage(path, now) end, nonblock: true)
    |> stage_result()
  end

  # sobelow_skip ["Traversal.FileModule"] — removes only an expired stage directory, never its lock.
  @spec remove_expired_stage(String.t(), integer()) :: :ok
  defp remove_expired_stage(path, now) do
    if directory?(path) and stage_deadline(path) < now, do: File.rm_rf!(path)
    :ok
  end

  @spec stage_result(:ok | {:error, term()}) :: {:cont, :ok} | {:halt, {:error, term()}}
  defp stage_result(:ok), do: {:cont, :ok}
  defp stage_result({:error, {:lock_exit, 75}}), do: {:cont, :ok}
  defp stage_result({:error, _} = error), do: {:halt, error}

  # sobelow_skip ["Traversal.FileModule"] — reads `.deadline` inside a matched stage directory.
  @spec stage_deadline(String.t()) :: integer()
  defp stage_deadline(path) do
    case File.read(Path.join(path, ".deadline")) do
      {:ok, value} ->
        case Integer.parse(value) do
          {deadline, ""} -> deadline
          _ -> legacy_deadline(path)
        end

      {:error, :enoent} ->
        legacy_deadline(path)

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read stage deadline", path: path
    end
  end

  # sobelow_skip ["Traversal.FileModule"] — stats a matched stage directory.
  @spec legacy_deadline(String.t()) :: integer()
  defp legacy_deadline(path), do: File.stat!(path, time: :posix).mtime * 1000 + @legacy_stage_timeout_ms

  # sobelow_skip ["Traversal.FileModule"] — path is a generation manifest or its usage sidecar.
  @spec read_json(String.t()) :: map()
  defp read_json(path) do
    case File.read(path) do
      {:ok, data} ->
        case Jason.decode!(data) do
          metadata when is_map(metadata) -> metadata
          _ -> raise File.Error, reason: :einval, action: "read cache metadata", path: path
        end

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read cache metadata", path: path
    end
  end

  @spec read_usage(String.t()) :: map()
  defp read_usage(path) do
    usage = read_json(path)

    if Enum.all?(usage, fn {family, timestamp} -> is_binary(family) and is_integer(timestamp) end) do
      usage
    else
      raise File.Error, reason: :einval, action: "read cache usage", path: path
    end
  end

  # sobelow_skip ["Traversal.FileModule"] — lstats a path already joined under the cache root.
  @spec directory?(String.t()) :: boolean()
  defp directory?(path), do: match?({:ok, %{type: :directory}}, File.lstat(path))

  # sobelow_skip ["Traversal.FileModule"] — stats the usage sidecar of a generation directory.
  @spec optional_bytes(String.t()) :: non_neg_integer()
  defp optional_bytes(path) do
    case File.lstat(path) do
      {:ok, stat} -> stat.size
      {:error, :enoent} -> 0
      {:error, reason} -> raise File.Error, reason: reason, action: "stat cache metadata", path: path
    end
  end

  # sobelow_skip ["Traversal.FileModule"] — walks a cache-root child without following symlinks.
  @spec bytes(String.t()) :: non_neg_integer()
  defp bytes(path) do
    case File.lstat!(path) do
      %{type: :directory} -> path |> File.ls!() |> Enum.map(&bytes(Path.join(path, &1))) |> Enum.sum()
      %{size: size} -> size
    end
  end
end
