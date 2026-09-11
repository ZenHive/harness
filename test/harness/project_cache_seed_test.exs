defmodule Harness.ProjectCacheSeedTest do
  use ExUnit.Case, async: false

  alias Harness.GitFixture
  alias Harness.ProjectCache
  alias Harness.ProjectCache.Recipe
  alias Harness.ProjectFixture
  alias Harness.Worktree

  setup do
    repo = GitFixture.init_repo()
    File.write!(Path.join(repo, ".gitignore"), "deps/\n")
    File.write!(Path.join(repo, "app"), "one")
    File.write!(Path.join(repo, "lock"), "dependency")
    GitFixture.git!(repo, ["add", ".gitignore", "app", "lock"])
    GitFixture.git!(repo, ["commit", "-qm", "inputs"])

    seed = %{
      "commands" => ["mkdir deps; cp lock deps/dependency; cp app deps/app"],
      "paths" => ["deps"],
      "inputs" => ["lock"],
      "identity_commands" => ["printf tool"],
      "env_inputs" => []
    }

    recipe = %{
      "commands" => ["test -f deps/dependency; cp app deps/app; test -s deps/app"],
      "paths" => ["deps"],
      "identity_commands" => ["printf tool"],
      "env_inputs" => [],
      "seed" => seed
    }

    %{
      repo: repo,
      project: ProjectFixture.from_repo(repo),
      base: GitFixture.tmp_base(),
      cache: GitFixture.tmp_base(),
      recipe: recipe
    }
  end

  test "application revisions reuse seed bytes but execute full preparation before publishing", c do
    assert {:ok, cold} = prepare(c)
    change(c, "app", "two")
    assert {:ok, warm} = prepare(c)
    assert cold.key != warm.key
    assert cold.seed["state"] == "built"
    assert warm.seed["state"] == "hit"
    assert cold.seed["key"] == warm.seed["key"]
    assert File.read!(Path.join([c.cache, warm.key, "deps/app"])) == "two"
    assert File.read!(Path.join([c.cache, cold.seed["key"], "deps/app"])) == "one"
    assert {:ok, %{state: :hit, key: key}} = prepare(c)
    assert key == warm.key
  end

  test "lock, configuration, local dependency, tool and seed environment invalidate full and seed generations", c do
    recipe = put_in(c.recipe, ["seed", "inputs"], ["lock", "config", "vendor"])
    c = %{c | recipe: recipe}
    assert {:ok, original} = prepare(c)

    current =
      Enum.reduce(["lock", "config", "vendor"], original, fn path, previous ->
        change(c, path, "changed")
        assert {:ok, changed} = prepare(c)
        assert changed.key != previous.key
        assert changed.seed["key"] != previous.seed["key"]
        assert changed.seed["state"] == "built"
        changed
      end)

    for recipe <- [
          put_in(recipe, ["seed", "env"], %{"FLAVOR" => "other"}),
          put_in(recipe, ["seed", "identity_commands"], ["printf new-tool"])
        ] do
      assert {:ok, changed} = prepare(%{c | recipe: recipe})
      assert changed.key != current.key
      assert changed.seed["key"] != current.seed["key"]
    end
  end

  test "seed identity is probed once and the resolved key is used by the builder", c do
    File.mkdir_p!(c.base)
    calls = Path.join(c.base, "identity-calls")

    recipe =
      c.recipe
      |> put_in(["seed", "env"], %{"CALLS" => calls})
      |> put_in(["seed", "identity_commands"], [~s(printf 'probe\\n' >> "$CALLS"; pwd)])

    wt = tree(c)
    assert {:ok, cold} = ProjectCache.prepare(wt, recipe, cache_root: c.cache)
    assert File.read!(calls) == "probe\n"
    assert File.regular?(Path.join([c.cache, cold.seed["key"], "complete.json"]))
    assert {:ok, %{state: :hit, key: key}} = ProjectCache.prepare(wt, recipe, cache_root: c.cache)
    assert key == cold.key
    assert File.read!(calls) == "probe\nprobe\n"
  end

  test "seed timeout bounds identity probes as well as build commands", c do
    recipe =
      c.recipe
      |> put_in(["seed", "identity_commands"], ["sleep 30"])
      |> put_in(["seed", "timeout_ms"], 250)

    started = System.monotonic_time(:millisecond)
    assert {:error, {:preparation_command, 1, :timeout}} = prepare(%{c | recipe: recipe})
    assert System.monotonic_time(:millisecond) - started < 5_000
    assert Path.wildcard(Path.join(c.cache, "*/complete.json")) == []
  end

  test "seed timeout publishes neither a partial seed nor a final generation", c do
    recipe =
      c.recipe
      |> put_in(["seed", "commands"], ["mkdir deps; sleep 30"])
      |> put_in(["seed", "timeout_ms"], 500)

    assert {:error, {:preparation_command, 1, :timeout}} = prepare(%{c | recipe: recipe})
    assert Path.wildcard(Path.join(c.cache, "*/complete.json")) == []
    assert Path.wildcard(Path.join(c.cache, "*.building-*")) == []
  end

  test "seed-only inherited environment and live tool identity also invalidate a final hit", c do
    variable = "HARNESS_SEED_TEST_FLAVOR"
    previous = System.get_env(variable)

    on_exit(fn ->
      if previous, do: System.put_env(variable, previous), else: System.delete_env(variable)
    end)

    File.mkdir_p!(c.base)
    identity = Path.join(c.base, "identity")
    File.write!(identity, "one")

    recipe =
      c.recipe
      |> put_in(["seed", "env_inputs"], [variable])
      |> put_in(["seed", "env"], %{"IDENTITY" => identity})
      |> put_in(["seed", "identity_commands"], [~s(cat "$IDENTITY")])

    c = %{c | recipe: recipe}
    System.put_env(variable, "one")
    assert {:ok, first} = prepare(c)
    System.put_env(variable, "two")
    assert {:ok, second} = prepare(c)
    assert first.key != second.key
    assert first.seed["key"] != second.seed["key"]
    File.write!(identity, "two")
    assert {:ok, third} = prepare(c)
    assert second.key != third.key
    assert second.seed["key"] != third.seed["key"]
  end

  test "cancelling a seed builder releases both locks and preserves no partial generation", c do
    File.mkdir_p!(c.base)
    ready = Path.join(c.base, "ready")
    permit = Path.join(c.base, "permit")

    recipe =
      c.recipe
      |> put_in(["seed", "env"], %{"READY" => ready, "PERMIT" => permit})
      |> put_in(["seed", "commands"], [
        ~s(mkdir deps; cp lock deps/dependency; if test ! -f "$PERMIT"; then echo ready > "$READY"; sleep 30; fi)
      ])

    wt = tree(c)
    caller = Task.async(fn -> ProjectCache.prepare(wt, recipe, cache_root: c.cache) end)
    await_file(ready)
    Task.shutdown(caller, :brutal_kill)
    File.write!(permit, "continue")
    assert {:ok, %{state: :built}} = ProjectCache.prepare(wt, recipe, cache_root: c.cache)
    assert [_, _] = Path.wildcard(Path.join(c.cache, "*/complete.json"))
    assert Path.wildcard(Path.join(c.cache, "*.building-*")) == []
  end

  test "failed full preparation cannot turn a reusable stale seed into a published result", c do
    assert {:ok, original} = prepare(c)
    change(c, "app", "")
    assert {:error, {:preparation_command, 1, {:command_exit, 1, _}}} = prepare(c)
    assert [_, _] = Path.wildcard(Path.join(c.cache, "*/complete.json"))
    assert File.read!(Path.join([c.cache, original.seed["key"], "deps/app"])) == "one"
    assert Path.wildcard(Path.join(c.cache, "*.building-*")) == []
  end

  test "concurrent revisions share one seed and keep their final artifacts isolated", c do
    trees =
      for value <- ["two", "three", "four"] do
        change(c, "app", value)
        {tree(c), value}
      end

    results =
      trees
      |> Task.async_stream(
        fn {wt, value} ->
          assert {:ok, report} = ProjectCache.prepare(wt, c.recipe, cache_root: c.cache)
          assert File.read!(Path.join(wt.path, "deps/app")) == value
          report
        end,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, report} -> report end)

    assert Enum.count(results, &(&1.seed["state"] == "built")) == 1
    assert results |> Enum.map(& &1.seed["key"]) |> Enum.uniq() |> length() == 1
    assert results |> Enum.map(& &1.key) |> Enum.uniq() |> length() == 3
  end

  test "nested seeds and seed outputs outside the owning recipe are rejected", c do
    for seed <- [42, Map.put(c.recipe["seed"], "seed", c.recipe["seed"]), Map.put(c.recipe["seed"], "paths", ["_build"])] do
      assert {:error, :invalid_cache_preparation} = Recipe.normalize(Map.put(c.recipe, "seed", seed))
    end

    assert {:ok, _} = Recipe.normalize(Map.put(c.recipe, "seed", nil))
  end

  defp prepare(c), do: ProjectCache.prepare(tree(c), c.recipe, cache_root: c.cache)

  defp tree(c) do
    {:ok, wt} = Worktree.create(c.project, base_dir: c.base)
    wt
  end

  defp change(c, path, value) do
    File.write!(Path.join(c.repo, path), value)
    GitFixture.git!(c.repo, ["add", path])
    GitFixture.git!(c.repo, ["commit", "-qm", "change"])
  end

  defp await_file(path, attempts \\ 500)
  defp await_file(_path, 0), do: flunk("seed did not reach cancellation point")

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
end
