defmodule Harness.ProjectCache.RetentionTest do
  use ExUnit.Case, async: true

  alias Harness.GitFixture
  alias Harness.ProjectCache.Command
  alias Harness.ProjectCache.Retention

  setup do
    root = GitFixture.tmp_base()
    File.mkdir_p!(root)
    %{root: root, now: System.system_time(:nanosecond)}
  end

  test "idle bound retains most recently used per repository and kind, not most recently created", c do
    outer = Retention.family("/repo/a", :outer)
    seed = Retention.family("/repo/a", :seed)
    other = Retention.family("/repo/b", :outer)
    old = generation(c, 1, outer, 30)
    recent = generation(c, 2, outer, 20)
    seed_path = generation(c, 3, seed, 30)
    other_path = generation(c, 4, other, 30)
    assert :ok = Retention.used(old, outer)
    assert {:ok, _} = reclaim(c.root, max_idle_ms: 1)
    assert File.dir?(old)
    refute File.exists?(recent)
    assert File.dir?(seed_path)
    assert File.dir?(other_path)
  end

  test "bytes cap evicts LRU entries until below cap even if they are not idle", c do
    family = Retention.family("/repo", :outer)
    paths = for n <- 1..3, do: generation(c, n, family, 4 - n)
    assert {:ok, %{over_budget: false, bytes: remaining}} = reclaim(c.root, max_bytes: 2500)
    assert remaining <= 2500
    [oldest, middle, newest] = paths
    refute File.exists?(oldest)
    assert File.dir?(middle)
    assert File.dir?(newest)
  end

  test "protected generations may exceed the cap and report it", c do
    path = generation(c, 1, "family", 30)
    assert {:ok, %{over_budget: true}} = reclaim(c.root, max_bytes: 1)
    assert File.dir?(path)
  end

  test "legacy entries are evictable; reuse associates a known family without changing artifacts", c do
    old = generation(c, 1, nil, 30)
    reused = generation(c, 2, nil, 30)
    manifest = File.read!(Path.join(reused, "complete.json"))
    assert :ok = Retention.used(reused, Retention.family("/repo", :outer))
    assert {:ok, _} = reclaim(c.root, max_idle_ms: 1)
    refute File.exists?(old)
    assert File.dir?(reused)
    assert File.read!(Path.join(reused, "complete.json")) == manifest
  end

  test "a generation used as both seed and outer retains both family histories", c do
    path = generation(c, 1, "outer", 10)
    assert :ok = Retention.used(path, "seed")
    assert :ok = Retention.used(path, "outer")
    assert (path <> ".usage") |> File.read!() |> Jason.decode!() |> Map.keys() |> Enum.sort() == ["outer", "seed"]
  end

  test "shared root reader excludes reclamation; lock inodes survive cleanup", c do
    path = generation(c, 1, nil, 30)
    lock = path <> ".lock"
    File.write!(lock, "")
    inode = File.stat!(lock).inode
    holder = hold_lock(Retention.lock_path(c.root), shared: true)
    assert {:error, {:lock_exit, 75}} = reclaim(c.root, max_idle_ms: 1)
    assert File.dir?(path)
    release(holder)
    assert {:ok, _} = reclaim(c.root, max_idle_ms: 1)
    refute File.exists?(path)
    assert File.stat!(lock).inode == inode
    assert File.regular?(Retention.lock_path(c.root))
  end

  test "a held per-key lock also prevents removal", c do
    path = generation(c, 1, nil, 30)
    holder = hold_lock(path <> ".lock")
    inode = File.stat!(path <> ".lock").inode
    assert {:ok, _} = reclaim(c.root, max_idle_ms: 1)
    assert File.dir?(path)
    assert File.stat!(path <> ".lock").inode == inode
    release(holder)
    assert {:ok, _} = reclaim(c.root, max_idle_ms: 1)
    refute File.exists?(path)
  end

  test "only abandoned stages past their deadline are removed, including legacy stages", c do
    now = System.system_time(:millisecond)
    expired = stage(c, 1, now - 1)
    fresh = stage(c, 2, now + 60_000)
    legacy = stage(c, 3, nil)
    File.touch!(legacy, div(now, 1000) - 3600)
    held = stage(c, 4, now - 1)
    holder = hold_lock(Path.join(c.root, key(4) <> ".lock"))
    assert {:ok, _} = reclaim(c.root)
    refute File.exists?(expired)
    refute File.exists?(legacy)
    assert File.dir?(fresh)
    assert File.dir?(held)
    release(holder)
    assert {:ok, _} = reclaim(c.root)
    refute File.exists?(held)
  end

  test "unrelated directories and symlinks are not traversed for deletion", c do
    outside = GitFixture.tmp_base()
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "valuable"), "keep")
    File.ln_s!(outside, Path.join(c.root, key(1)))
    unrelated = Path.join(c.root, "unrelated.building-old")
    File.mkdir_p!(unrelated)
    assert {:ok, _} = reclaim(c.root, max_bytes: 1)
    assert File.read!(Path.join(outside, "valuable")) == "keep"
    assert File.dir?(unrelated)
    assert {:ok, ^outside} = File.read_link(Path.join(c.root, key(1)))
  end

  test "expired or cancelled maintenance does not remove generations", c do
    path = generation(c, 1, nil, 30)
    assert {:error, :timeout} = Retention.reclaim(c.root, make_ref(), System.monotonic_time(:millisecond) - 1)
    owner = make_ref()
    send(self(), {:DOWN, owner, :process, self(), :normal})
    assert {:error, :interrupted} = Retention.reclaim(c.root, owner, System.monotonic_time(:millisecond) + 5000)
    assert File.dir?(path)
  end

  test "malformed metadata reports failure without deleting generations", c do
    path = generation(c, 1, nil, 30)

    for malformed <- ["not json", "[]", ~s({"family":"yesterday"})] do
      File.write!(path <> ".usage", malformed)
      assert {:error, {:cache_retention, _}} = reclaim(c.root, max_bytes: 1)
      assert {:error, {:cache_usage, _}} = Retention.used(path, "family")
      assert File.dir?(path)
    end
  end

  @spec generation(map(), integer(), String.t() | nil, integer()) :: String.t()
  defp generation(c, n, family, age_seconds) do
    path = Path.join(c.root, key(n))
    File.mkdir_p!(path)
    manifest = %{source: "/deleted/cache/stage/source", commands: 1, exit_status: 0}
    manifest = if family, do: Map.put(manifest, :retention_family, family), else: manifest
    File.write!(Path.join(path, "complete.json"), Jason.encode!(manifest))
    File.write!(Path.join(path, "payload"), String.duplicate("x", 1000))
    File.touch!(path, div(c.now, 1_000_000_000) - age_seconds)
    if family, do: File.write!(path <> ".usage", Jason.encode!(%{family => c.now - age_seconds * 1_000_000_000}))
    path
  end

  @spec stage(map(), integer(), integer() | nil) :: String.t()
  defp stage(c, n, deadline) do
    path = Path.join(c.root, key(n) <> ".building-test")
    File.mkdir_p!(path)
    if deadline, do: File.write!(Path.join(path, ".deadline"), Integer.to_string(deadline))
    path
  end

  @spec key(integer()) :: String.t()
  defp key(n), do: n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0")

  @spec reclaim(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defp reclaim(root, opts \\ []) do
    Retention.reclaim(root, make_ref(), System.monotonic_time(:millisecond) + 5000, opts)
  end

  @spec hold_lock(String.t(), keyword()) :: Task.t()
  defp hold_lock(path, opts \\ []) do
    parent = self()

    task =
      Task.async(fn ->
        Command.locked(
          path,
          make_ref(),
          System.monotonic_time(:millisecond) + 5000,
          fn ->
            send(parent, {:held, self()})

            receive do
              :release -> :ok
            after
              5000 -> flunk("lock was never released")
            end
          end,
          opts
        )
      end)

    pid = task.pid
    assert_receive {:held, ^pid}, 5000
    task
  end

  @spec release(Task.t()) :: :ok
  defp release(task) do
    send(task.pid, :release)
    assert Task.await(task) == :ok
    :ok
  end
end
