defmodule Harness.ProjectCachePltTest do
  use ExUnit.Case, async: true

  alias Harness.GitFixture
  alias Harness.ProjectCache
  alias Harness.ProjectFixture
  alias Harness.Worktree

  @tag timeout: 180_000
  test "real Elixir dependency builds in dev/test and a relocated project PLT survives normal checking" do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    cache = GitFixture.tmp_base()
    File.mkdir_p!(Path.join(repo, "vendor/cache_dep/lib"))
    File.mkdir_p!(Path.join(repo, "priv"))
    File.mkdir_p!(Path.join(repo, "lib"))
    File.write!(Path.join(repo, "priv/resource.txt"), "tracked resource")

    File.write!(
      Path.join(repo, "lib/cache_consumer.ex"),
      "defmodule CacheConsumer do\n def answer, do: CacheDependency.increment(41)\nend\n"
    )

    File.write!(Path.join(repo, ".gitignore"), "_build/\npriv/plts/\n")

    File.write!(Path.join(repo, "mix.exs"), """
    defmodule CacheConsumer.MixProject do
      use Mix.Project
      def project, do: [app: :cache_consumer, version: "0.1.0", deps: [{:cache_dep, path: "vendor/cache_dep"}]]
    end
    """)

    File.write!(Path.join(repo, "vendor/cache_dep/mix.exs"), """
    defmodule CacheDependency.MixProject do
      use Mix.Project
      def project, do: [app: :cache_dep, version: "0.1.0"]
    end
    """)

    File.write!(Path.join(repo, "vendor/cache_dep/lib/cache_dep.ex"), """
    defmodule CacheDependency do
      @spec increment(integer()) :: integer()
      def increment(value), do: value + 1
    end
    """)

    GitFixture.git!(repo, ["add", "mix.exs", "vendor", "priv/resource.txt", "lib", ".gitignore"])
    GitFixture.git!(repo, ["commit", "-qm", "real Elixir cache fixture"])
    project = ProjectFixture.from_repo(repo)
    {:ok, first} = Worktree.create(project, base_dir: base)
    {:ok, second} = Worktree.create(project, base_dir: base)
    helper = Application.app_dir(:harness, "priv/cache/relocate_plt.exs")
    elixir_ebin = :elixir |> :code.lib_dir() |> List.to_string() |> Path.join("ebin")
    env = %{"ERL_FLAGS" => "+S 2:2"}

    recipe = %{
      "commands" => [
        "MIX_ENV=dev mix deps.compile",
        "MIX_ENV=dev mix compile",
        "MIX_ENV=test mix deps.compile",
        "MIX_ENV=test mix compile",
        "mkdir -p priv/plts",
        "dialyzer -pa '#{elixir_ebin}' --build_plt --output_plt priv/plts/project.plt _build/dev/lib/cache_dep/ebin/*.beam --apps erts kernel stdlib compiler crypto parsetools syntax_tools"
      ],
      "identity_commands" => ["elixir --version", "dialyzer --version"],
      "restore_commands" => ["elixir '#{helper}' priv/plts/project.plt"],
      "paths" => ["_build", "priv/plts"],
      "env" => env
    }

    refute File.exists?(Path.join(repo, "priv/plts/project.plt"))
    assert {:ok, %{state: :built} = cold} = ProjectCache.prepare(first, recipe, cache_root: cache)
    assert {:ok, %{state: :hit} = warm} = ProjectCache.prepare(second, recipe, cache_root: cache)
    assert cold.key == warm.key

    for wt <- [first, second] do
      assert File.read!(Path.join(wt.path, "_build/dev/lib/cache_consumer/priv/resource.txt")) == "tracked resource"

      for environment <- ["dev", "test"] do
        assert File.regular?(Path.join(wt.path, "_build/#{environment}/lib/cache_dep/ebin/Elixir.CacheDependency.beam"))
      end

      {output, status} =
        System.cmd("dialyzer", ["-pa", elixir_ebin, "--check_plt", "--plt", "priv/plts/project.plt"],
          cd: wt.path,
          env: Map.to_list(env),
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "up-to-date"

      {output, status} =
        System.cmd("elixir", ["-pa", "_build/test/lib/cache_dep/ebin", "-e", "IO.puts(CacheDependency.increment(41))"],
          cd: wt.path,
          env: Map.to_list(env),
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert String.trim(output) == "42"
    end

    # A negative control proves why unrelocated byte copies are not enough.
    original = Path.join([cache, cold.key, "priv/plts/project.plt"])

    {output, status} =
      System.cmd("dialyzer", ["-pa", elixir_ebin, "--check_plt", "--plt", original],
        cd: second.path,
        env: Map.to_list(env),
        stderr_to_stdout: true
      )

    assert status == 1, output
    assert output =~ "File not found:"

    assert File.read!(Path.join(first.path, "priv/plts/project.plt")) != File.read!(original)
    assert File.stat!(original).size > 0

    IO.puts(
      "CACHE_PLT_EVIDENCE " <>
        Jason.encode!(%{
          cold_ms: cold.elapsed_ms,
          warm_ms: warm.elapsed_ms,
          plt_bytes: File.stat!(original).size,
          copied: warm.copied,
          dependency_modules: 1,
          normal_plt_checks: 2,
          unrelocated_negative_control_status: status
        })
    )
  end
end
