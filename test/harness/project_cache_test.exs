defmodule Harness.ProjectCacheTest do
  use ExUnit.Case, async: true

  alias Harness.GitFixture
  alias Harness.ProjectCache
  alias Harness.ProjectCache.Recipe
  alias Harness.ProjectFixture
  alias Harness.Worktree

  setup do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    cache = GitFixture.tmp_base()
    File.write!(Path.join(repo, ".gitignore"), "deps/\n_build/\npriv/plts/\nassets/node_modules/\n")
    File.write!(Path.join(repo, "mix.lock"), "lock-one")
    GitFixture.git!(repo, ["add", "mix.lock", ".gitignore"])
    GitFixture.git!(repo, ["commit", "-qm", "lock"])
    project = ProjectFixture.from_repo(repo)
    {:ok, wt} = Worktree.create(project, base_dir: base)
    %{repo: repo, base: base, cache: cache, project: project, wt: wt}
  end

  test "real cold preparation, concurrent deduplication and isolated non-clobbering copies", c do
    recipe = recipe(c, "printf build\\n >> \"$COUNTER\"; mkdir -p deps; printf prepared > deps/value")
    worktrees = for _ <- 1..6, do: new_tree(c)

    results =
      worktrees
      |> Task.async_stream(&ProjectCache.prepare(&1, recipe, cache_root: c.cache), timeout: 20_000)
      |> Enum.map(fn {:ok, {:ok, report}} -> report end)

    assert Enum.count(results, &(&1.state == :built)) == 1
    assert Enum.count(results, &(&1.state == :hit)) == 5
    assert results |> Enum.map(& &1.key) |> Enum.uniq() |> length() == 1
    assert File.read!(Path.join(c.base, "counter")) == "buildn"
    refute File.exists?(Path.join(c.repo, "deps"))
    [first, second | _] = worktrees
    File.write!(Path.join(first.path, "deps/value"), "agent")
    assert File.read!(Path.join(second.path, "deps/value")) == "prepared"
    assert {:ok, %{state: :hit, copied: []}} = ProjectCache.prepare(first, recipe, cache_root: c.cache)
    assert File.read!(Path.join(first.path, "deps/value")) == "agent"
    assert Path.wildcard(Path.join(c.cache, "*.building-*")) == []
  end

  test "committed input, recipe, toolchain and environment changes invalidate; unrelated changes can reuse", c do
    recipe = Map.put(recipe(c), "inputs", ["mix.lock"])
    assert {:ok, a} = ProjectCache.prepare(c.wt, recipe, cache_root: c.cache)
    File.write!(Path.join(c.repo, "README.md"), "unrelated")
    commit(c.repo, "README.md")
    assert {:ok, %{key: key, state: :hit}} = ProjectCache.prepare(new_tree(c), recipe, cache_root: c.cache)
    assert key == a.key

    File.write!(Path.join(c.repo, "mix.lock"), "lock-two")
    commit(c.repo, "mix.lock")
    assert {:ok, b} = ProjectCache.prepare(new_tree(c), recipe, cache_root: c.cache)
    assert b.key != a.key
    assert b.state == :built

    for changed <- [
          Map.put(recipe, "version", "2"),
          Map.put(recipe, "identity_commands", ["printf tool-two"]),
          put_in(recipe, ["env", "BUILD_FLAVOR"], "test")
        ] do
      assert {:ok, report} = ProjectCache.prepare(new_tree(c), changed, cache_root: c.cache)
      assert report.key != b.key
      assert report.state == :built
    end
  end

  test "failed command publishes nothing and a retry can prepare the same key", c do
    recipe = recipe(c, "mkdir -p deps; printf partial > deps/value; test -f \"$COUNTER\"")

    assert {:error, {:preparation_command, 1, {:command_exit, 1, _}}} =
             ProjectCache.prepare(c.wt, recipe, cache_root: c.cache)

    assert Path.wildcard(Path.join(c.cache, "*/complete.json")) == []
    refute File.exists?(Path.join(c.wt.path, "deps"))
    File.mkdir_p!(c.base)
    File.write!(Path.join(c.base, "counter"), "allow")
    assert {:ok, %{state: :built}} = ProjectCache.prepare(c.wt, recipe, cache_root: c.cache)
  end

  test "timeout kills the command and does not publish partial output", c do
    recipe = c |> recipe("mkdir -p deps; printf partial > deps/value; sleep 30") |> Map.put("timeout_ms", 200)
    assert {:error, {:preparation_command, 1, :timeout}} = ProjectCache.prepare(c.wt, recipe, cache_root: c.cache)
    assert Path.wildcard(Path.join(c.cache, "*/complete.json")) == []
    assert Path.wildcard(Path.join(c.cache, "*.building-*")) == []
  end

  test "caller interruption cannot publish; lock releases and retry succeeds", c do
    File.mkdir_p!(c.base)
    fifo = Path.join(c.base, "ready")

    recipe =
      recipe(
        c,
        ~s(mkdir -p deps; printf partial > deps/value; if test ! -f "$COUNTER"; then printf ready > "$READY"; sleep 30; fi)
      )

    recipe = put_in(recipe, ["env", "READY"], fifo)
    caller = Task.async(fn -> ProjectCache.prepare(c.wt, recipe, cache_root: c.cache) end)
    await_file(fifo)
    assert File.read!(fifo) == "ready"
    Task.shutdown(caller, :brutal_kill)
    File.write!(Path.join(c.base, "counter"), "retry")
    assert {:ok, %{state: :built}} = ProjectCache.prepare(c.wt, recipe, cache_root: c.cache)
    assert [_manifest] = Path.wildcard(Path.join(c.cache, "*/complete.json"))
    assert Path.wildcard(Path.join(c.cache, "*.building-*")) == []
  end

  test "legacy warm_paths works, declared failed outputs cannot fall back to stale parent bytes, cold create stays cold",
       c do
    for path <- ["deps", "assets/node_modules"] do
      File.mkdir_p!(Path.join(c.repo, path))
      File.write!(Path.join([c.repo, path, "value"]), "parent")
    end

    refute File.exists?(Path.join(c.wt.path, "deps"))
    assert :ok = ProjectCache.warm(c.wt, recipe(c, "exit 7"), cache_root: c.cache, warm_paths: ["assets/node_modules"])
    refute File.exists?(Path.join(c.wt.path, "deps"))
    assert File.read!(Path.join(c.wt.path, "assets/node_modules/value")) == "parent"
    assert :ok = ProjectCache.warm(c.wt, nil)
    assert File.read!(Path.join(c.wt.path, "deps/value")) == "parent"
    cold = new_tree(c)
    refute File.exists?(Path.join(cold.path, "deps"))
  end

  test "missing, tracked and escaping output paths do not publish", c do
    for {command, paths} <- [
          {"true", ["deps"]},
          {"true", ["README.md"]},
          {"mkdir -p deps; ln -s /tmp deps/link", ["deps"]},
          {"ln -s /tmp deps", ["deps"]}
        ] do
      recipe = c |> recipe(command) |> Map.put("paths", paths)
      assert {:error, _} = ProjectCache.prepare(c.wt, recipe, cache_root: c.cache)
    end

    assert Path.wildcard(Path.join(c.cache, "*/complete.json")) == []
  end

  test "existing dangling symlinks and symlink parents are never clobbered", c do
    File.ln_s!("missing", Path.join(c.wt.path, "deps"))
    assert {:ok, %{copied: []}} = ProjectCache.prepare(c.wt, recipe(c), cache_root: c.cache)
    assert File.read_link!(Path.join(c.wt.path, "deps")) == "missing"

    another = new_tree(c)
    File.mkdir_p!(c.base)
    File.ln_s!(c.base, Path.join(another.path, "assets"))
    recipe = recipe(c, "mkdir -p assets/node_modules; printf prepared > assets/node_modules/value")
    recipe = Map.put(recipe, "paths", ["assets/node_modules"])
    assert {:error, {:unsafe_cache_parent, "assets"}} = ProjectCache.prepare(another, recipe, cache_root: c.cache)
    refute File.exists?(Path.join(c.base, "node_modules"))
  end

  test "external process locks serialize preparation and cancelled waiters do not block reuse", c do
    assert {:ok, %{key: key}} = ProjectCache.prepare(c.wt, recipe(c), cache_root: c.cache)

    holder =
      Port.open({:spawn_executable, System.find_executable("flock")}, [
        :binary,
        :exit_status,
        args: ["-x", Path.join(c.cache, key <> ".lock"), "sh", "-c", "printf held; cat >/dev/null"]
      ])

    assert_receive {^holder, {:data, "held"}}, 5000
    waiting = Task.async(fn -> ProjectCache.prepare(new_tree(c), recipe(c), cache_root: c.cache) end)
    assert Task.yield(waiting, 100) == nil
    Task.shutdown(waiting, :brutal_kill)
    Port.close(holder)
    assert {:ok, %{state: :hit}} = ProjectCache.prepare(new_tree(c), recipe(c), cache_root: c.cache)
  end

  test "restore failures discard staged artifacts without changing the completed generation", c do
    recipe = Map.put(recipe(c), "restore_commands", ["printf altered > deps/value; exit 9"])

    assert {:error, {:cache_restore, {:preparation_command, 1, {:command_exit, 9, _}}}} =
             ProjectCache.prepare(c.wt, recipe, cache_root: c.cache)

    refute File.exists?(Path.join(c.wt.path, "deps"))
    assert [original] = Path.wildcard(Path.join(c.cache, "*/deps/value"))
    assert File.read!(original) == "prepared"
    assert Path.wildcard(Path.join(c.wt.path, ".harness/cache-seed-*")) == []
  end

  test "toolchain probe errors cannot turn into hits or preparation", c do
    recipe = Map.put(recipe(c), "identity_commands", ["exit 6"])

    assert {:error, {:preparation_command, 1, {:command_exit, 6, _}}} =
             ProjectCache.prepare(c.wt, recipe, cache_root: c.cache)

    assert Path.wildcard(Path.join(c.cache, "*/complete.json")) == []
  end

  test "unignored output is rejected and internal symlink chains remain isolated", c do
    unignored = c |> recipe("mkdir unignored") |> Map.put("paths", ["unignored"])

    assert {:error, {:cache_output_not_ignored, "unignored"}} =
             ProjectCache.prepare(c.wt, unignored, cache_root: c.cache)

    internal = recipe(c, "mkdir -p deps/real; printf value > deps/real/value; ln -s real deps/link")
    assert {:ok, _} = ProjectCache.prepare(c.wt, internal, cache_root: c.cache)
    assert File.read!(Path.join(c.wt.path, "deps/link/value")) == "value"

    for command <- [
          "mkdir -p deps/deep _build; ln -s ../../_build deps/deep/link; ln -s link/../../outside deps/deep/bad",
          "mkdir -p deps _build; ln -s second deps/first; ln -s first deps/second"
        ] do
      invalid = c |> recipe(command) |> Map.put("paths", ["deps", "_build"])
      assert {:error, {:external_cache_symlink, _}} = ProjectCache.prepare(new_tree(c), invalid, cache_root: c.cache)
    end
  end

  test "malformed completion manifests report errors, with an explicit version invalidation path", c do
    assert {:ok, %{key: key}} = ProjectCache.prepare(c.wt, recipe(c), cache_root: c.cache)
    File.write!(Path.join([c.cache, key, "complete.json"]), "{}")
    fresh = new_tree(c)
    assert {:error, {:cache_manifest, {:ok, %{}}}} = ProjectCache.prepare(fresh, recipe(c), cache_root: c.cache)
    refute File.exists?(Path.join(fresh.path, "deps"))
    assert {:ok, %{state: :built}} = ProjectCache.prepare(fresh, Map.put(recipe(c), "version", "2"), cache_root: c.cache)
  end

  test "a crashed preparation worker is a reported cache error and warm remains best effort", c do
    assert {:error, {:preparation_crashed, _}} = ProjectCache.prepare(c.wt, recipe(c), cache_root: nil)
    assert :ok = ProjectCache.warm(c.wt, recipe(c), cache_root: nil)
    refute File.exists?(Path.join(c.wt.path, "deps"))
  end

  test "recipe validation rejects malformed contracts", c do
    assert {:ok, nil} = Recipe.normalize(nil)
    assert :disabled = ProjectCache.prepare(c.wt, nil)
    assert {:error, :invalid_cache_preparation} = ProjectCache.prepare(c.wt, false)

    for path <- [nil, "", ".", "/absolute", ".git/index", "a/../b", "a" <> <<0>>] do
      refute Recipe.relative_path?(path)
    end

    for invalid <- [
          false,
          %{},
          Map.put(recipe(c), "commands", []),
          Map.put(recipe(c), "paths", ["../escape"]),
          Map.put(recipe(c), "paths", ["deps", "deps/nested"]),
          Map.put(recipe(c), "env", %{"X" => false}),
          Map.put(recipe(c), "env", []),
          Map.put(recipe(c), "env_inputs", false),
          Map.put(recipe(c), "timeout_ms", 0),
          Map.put(recipe(c), "unknown", true)
        ] do
      assert {:error, :invalid_cache_preparation} = Recipe.normalize(invalid)
    end
  end

  defp recipe(c, command \\ "mkdir -p deps; printf prepared > deps/value") do
    %{
      "commands" => [command],
      "identity_commands" => ["printf tool-one"],
      "paths" => ["deps"],
      "env" => %{"COUNTER" => Path.join(c.base, "counter")}
    }
  end

  defp new_tree(c) do
    {:ok, wt} = Worktree.create(c.project, base_dir: c.base)
    wt
  end

  defp await_file(path, attempts \\ 500)
  defp await_file(_path, 0), do: flunk("preparation never reached the interruption point")

  defp await_file(path, attempts) do
    if File.exists?(path) do
      :ok
    else
      receive do
      after
        10 -> await_file(path, attempts - 1)
      end
    end
  end

  defp commit(repo, path) do
    GitFixture.git!(repo, ["add", path])
    GitFixture.git!(repo, ["commit", "-qm", "fixture change"])
  end
end
