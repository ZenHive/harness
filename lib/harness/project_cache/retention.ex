defmodule Harness.ProjectCache.Retention do
  @moduledoc "Mechanical LRU reclamation of idle project-cache generations."

  alias Harness.Config
  alias Harness.ProjectCache.Command

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

  @doc "Reclaims idle generations when no preparation holds the root's shared lock."
  @spec reclaim(String.t(), reference(), integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def reclaim(root, owner, deadline, opts \\ []) do
    Command.locked(
      lock_path(root),
      owner,
      deadline,
      fn ->
        sweep(root, owner, deadline, opts)
      end,
      nonblock: true
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
      total = bytes(root)

      entries
      |> Enum.sort_by(&{&1.last_used, &1.path})
      |> Enum.reduce_while({:ok, total}, fn entry, {:ok, total} ->
        if not MapSet.member?(protected, entry.path) and (now - entry.last_used > idle or total > cap) do
          case remove(entry.path, owner, deadline) do
            :ok -> {:cont, {:ok, total - entry.bytes}}
            {:error, {:lock_exit, 75}} -> {:cont, {:ok, total}}
            {:error, _} = error -> {:halt, error}
          end
        else
          {:cont, {:ok, total}}
        end
      end)
      |> case do
        {:ok, remaining} -> {:ok, %{bytes: remaining, over_budget: remaining > cap}}
        {:error, _} = error -> error
      end
    end
  end

  @spec generations(String.t()) :: [map()]
  defp generations(root) do
    root
    |> File.ls!()
    |> Enum.filter(&Regex.match?(~r/\A[0-9a-f]{64}\z/, &1))
    |> Enum.map(&Path.join(root, &1))
    |> Enum.filter(&directory?/1)
    |> Enum.map(fn path ->
      manifest = read_json(Path.join(path, "complete.json"))
      usage = read_usage(path <> ".usage")
      fallback = File.stat!(path, time: :posix).mtime * 1_000_000_000
      uses = manifest |> manifest_uses(fallback) |> Map.merge(usage)
      last_used = uses |> Map.values() |> Enum.max(fn -> fallback end)
      %{path: path, uses: uses, last_used: last_used, bytes: bytes(path) + optional_bytes(path <> ".usage")}
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
        :ok
      end,
      nonblock: true
    )
  end

  @spec sweep_stages(String.t(), reference(), integer(), integer()) :: :ok | {:error, term()}
  defp sweep_stages(root, owner, deadline, now) do
    root
    |> File.ls!()
    |> Enum.filter(&Regex.match?(~r/\A[0-9a-f]{64}\.building-[A-Za-z0-9_-]+\z/, &1))
    |> Enum.reduce_while(:ok, fn name, :ok ->
      path = Path.join(root, name)
      [key, _suffix] = String.split(name, ".building-", parts: 2)

      result =
        Command.locked(
          Path.join(root, key <> ".lock"),
          owner,
          deadline,
          fn ->
            if directory?(path) and stage_deadline(path) < now, do: File.rm_rf!(path)
            :ok
          end,
          nonblock: true
        )

      case result do
        :ok -> {:cont, :ok}
        {:error, {:lock_exit, 75}} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

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

  @spec legacy_deadline(String.t()) :: integer()
  defp legacy_deadline(path), do: File.stat!(path, time: :posix).mtime * 1000 + @legacy_stage_timeout_ms

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

  @spec directory?(String.t()) :: boolean()
  defp directory?(path), do: File.lstat!(path).type == :directory

  @spec optional_bytes(String.t()) :: non_neg_integer()
  defp optional_bytes(path) do
    case File.lstat(path) do
      {:ok, stat} -> stat.size
      {:error, :enoent} -> 0
      {:error, reason} -> raise File.Error, reason: reason, action: "stat cache metadata", path: path
    end
  end

  @spec bytes(String.t()) :: non_neg_integer()
  defp bytes(path) do
    case File.lstat!(path) do
      %{type: :directory} -> path |> File.ls!() |> Enum.map(&bytes(Path.join(path, &1))) |> Enum.sum()
      %{size: size} -> size
    end
  end
end
