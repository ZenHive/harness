defmodule Harness.ProjectCacheTapaklyTest do
  use ExUnit.Case, async: false

  alias Harness.GitFixture
  alias Harness.ProjectCache
  alias Harness.ProjectFixture
  alias Harness.Worktree

  @moduletag :integration
  @moduletag timeout: 7_200_000

  test "real Tapakly revisions reuse dependency builds and PLTs while normal analysis checks changed code" do
    source = required_env("HARNESS_CACHE_TAPAKLY_SOURCE")
    evidence = required_env("HARNESS_CACHE_TAPAKLY_EVIDENCE")
    recipe_path = required_env("HARNESS_CACHE_TAPAKLY_RECIPE")
    File.mkdir_p!(evidence)
    repo = Path.join(evidence, "source")
    resume? = System.get_env("HARNESS_CACHE_TAPAKLY_RESUME") == "1"
    resume_env = System.get_env("HARNESS_CACHE_TAPAKLY_RESUME")
    System.delete_env("HARNESS_CACHE_TAPAKLY_RESUME")
    on_exit(fn -> if resume_env, do: System.put_env("HARNESS_CACHE_TAPAKLY_RESUME", resume_env) end)

    if resume? do
      assert File.dir?(Path.join(repo, ".git")), "resume requires the retained acceptance clone"
      assert String.trim(GitFixture.git!(repo, ["remote", "get-url", "origin"])) == source
      GitFixture.git!(repo, ["checkout", "--detach", "origin/HEAD"])
    else
      GitFixture.git!(evidence, ["clone", "--no-hardlinks", "--", source, repo])
    end

    GitFixture.git!(repo, ["config", "user.email", "cache-acceptance@example.invalid"])
    GitFixture.git!(repo, ["config", "user.name", "Cache acceptance"])
    upstream = GitFixture.git!(repo, ["rev-parse", "HEAD"])
    project = ProjectFixture.from_repo(repo)
    recipe = recipe_path |> File.read!() |> Jason.decode!()
    helper = Application.app_dir(:harness, "priv/cache/relocate_plt.exs")

    full =
      recipe
      |> Map.put("restore_commands", ["elixir '#{helper}' _build/dev/*.plt"])
      |> Map.put("env_inputs", nil)
      |> Map.update!("env", &Map.merge(&1, %{"ERL_FLAGS" => "+S 2:2", "MIX_ENV" => "dev"}))

    seed =
      full
      |> Map.put("exclude_inputs", ["lib", "test", "ROADMAP.md", "roadmap/data.json", "roadmap/tasks.toml"])
      |> Map.update!("commands", &measured(&1, "seed"))

    candidate =
      full
      |> Map.put("seed", seed)
      |> Map.put(
        "commands",
        measured(
          [
            "MIX_ENV=dev mix compile --force",
            "MIX_ENV=test mix compile --force",
            "MIX_ENV=dev mix dialyzer --plt --force-check"
          ],
          "application"
        )
      )

    write_probe(repo, "41")
    first = tree(project, evidence)
    assert {:ok, cold} = ProjectCache.prepare(first, candidate, cache_root: Path.join(evidence, "cache"))
    assert cold.seed["state"] == if(resume?, do: "hit", else: "built")
    record(evidence, "cold", cold, first)
    verify(first, evidence, "cold")

    write_probe(repo, "42")
    second = tree(project, evidence)
    assert first.base_sha != second.base_sha
    assert {:ok, warm} = ProjectCache.prepare(second, candidate, cache_root: Path.join(evidence, "cache"))
    record(evidence, "warm", warm, second)
    assert warm.seed["state"] == "hit"
    assert warm.seed["key"] == cold.seed["key"]
    assert warm.key != cold.key
    verify(second, evidence, "warm")

    assert normal(
             second,
             evidence,
             "value",
             "elixir -pa _build/dev/lib/tapakly/ebin -e 'IO.puts(Tapakly.CacheAcceptanceProbe.value())'"
           ) =~ "42"

    warm_log = File.read!(Path.join(second.path, "_build/cache-evidence/application-2.log"))
    assert warm_log =~ "Checking "
    assert warm_log =~ " modules in "
    refute warm_log =~ "Creating dialyxir"
    refute warm_log =~ "Copying dialyxir"
    seed_dependencies = dependency_digests(Path.join([evidence, "cache", cold.seed["key"]]))
    assert map_size(seed_dependencies) > 0

    for wt <- [first, second] do
      actual = dependency_digests(wt.path)
      assert actual |> Map.keys() |> Enum.sort() == seed_dependencies |> Map.keys() |> Enum.sort()
      changed = Enum.filter(seed_dependencies, fn {path, digest} -> actual[path] != digest end)
      assert changed == [], "dependency BEAM bytes changed: #{inspect(Enum.map(changed, &elem(&1, 0)))}"

      for index <- [0, 1] do
        output = File.read!(Path.join(wt.path, "_build/cache-evidence/application-#{index}.log"))

        for [_, app] <- Regex.scan(~r/^==> (.+)$/m, output) do
          assert app == "tapakly", "outer preparation recompiled dependency #{app}"
        end
      end
    end

    write_probe(repo, ~s("wrong"))
    invalid = tree(project, evidence)
    assert {:ok, rejected} = ProjectCache.prepare(invalid, candidate, cache_root: Path.join(evidence, "cache"))
    assert rejected.seed["state"] == "hit"
    {output, status} = run(invalid.path, "MIX_ENV=dev mix dialyzer", Path.join(evidence, "invalid-dialyzer.log"))
    assert status == 2, output
    assert output =~ "invalid_contract", output
    assert output =~ "Tapakly.CacheAcceptanceProbe.value/0", output
    assert output =~ "The @spec for the function does not match the success typing", output
    File.write!(Path.join(evidence, "upstream.txt"), upstream)
    File.write!(Path.join(evidence, "complete.json"), Jason.encode!(%{cold: cold, warm: warm, negative_status: status}))
  end

  test "measurement preserves shell quotes in the original recipe command" do
    cwd = GitFixture.tmp_base()
    File.mkdir_p!(cwd)
    [command] = measured([~S(printf '%s' 'quoted "value" and $HOME')], "quoted")
    assert {"", 0} = System.cmd("sh", ["-c", command], cd: cwd, stderr_to_stdout: true)

    assert File.read!(Path.join(cwd, "_build/cache-evidence/quoted-0.log")) =~
             ~S(quoted "value" and $HOME)
  end

  defp dependency_digests(root) do
    root
    |> Path.join("_build/{dev,test}/lib/*/ebin/*.beam")
    |> Path.wildcard()
    |> Enum.reject(&String.contains?(&1, "/lib/tapakly/"))
    |> Map.new(fn path -> {Path.relative_to(path, root), :crypto.hash(:sha256, File.read!(path))} end)
  end

  defp required_env(name) do
    System.get_env(name) ||
      flunk(
        "Missing #{name}. Set HARNESS_CACHE_TAPAKLY_SOURCE to a local https://github.com/ZenHive/tapakly checkout, HARNESS_CACHE_TAPAKLY_RECIPE to its reviewed recipe JSON, and HARNESS_CACHE_TAPAKLY_EVIDENCE to a fresh absolute evidence directory."
      )
  end

  defp measured(commands, prefix) do
    commands
    |> Enum.with_index()
    |> Enum.map(fn {command, index} ->
      "mkdir -p _build/cache-evidence; /usr/bin/time -f 'elapsed_seconds=%e max_rss_kb=%M' sh -c #{shell_quote(command)} > _build/cache-evidence/#{prefix}-#{index}.log 2>&1"
    end)
  end

  defp shell_quote(command), do: "'" <> String.replace(command, "'", "'\"'\"'") <> "'"

  defp write_probe(repo, expression) do
    path = "lib/tapakly/cache_acceptance_probe.ex"

    File.write!(Path.join(repo, path), """
    defmodule Tapakly.CacheAcceptanceProbe do
      @moduledoc false
      @spec value() :: integer()
      def value, do: #{expression}
    end
    """)

    GitFixture.git!(repo, ["add", path])
    GitFixture.git!(repo, ["commit", "-qm", "cache acceptance application revision"])
  end

  defp tree(project, evidence) do
    {:ok, wt} = Worktree.create(project, base_dir: Path.join(evidence, "worktrees"))
    wt
  end

  defp record(evidence, label, report, wt) do
    File.write!(Path.join(evidence, label <> ".json"), Jason.encode!(%{report: report, sha: wt.base_sha, path: wt.path}))
  end

  defp verify(wt, evidence, label) do
    normal(wt, evidence, label <> "-compile-dev", "MIX_ENV=dev mix compile --warnings-as-errors")
    normal(wt, evidence, label <> "-compile-test", "MIX_ENV=test mix compile --warnings-as-errors")
    normal(wt, evidence, label <> "-dialyzer", "MIX_ENV=dev mix dialyzer")
  end

  defp normal(wt, evidence, label, command) do
    {output, status} = run(wt.path, command, Path.join(evidence, label <> ".log"))
    assert status == 0, "#{label}: #{output}"
    output
  end

  defp run(cwd, command, log) do
    {output, status} = System.cmd("sh", ["-c", command], cd: cwd, env: [{"ERL_FLAGS", "+S 2:2"}], stderr_to_stdout: true)
    File.write!(log, output)
    {output, status}
  end
end
