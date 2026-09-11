defmodule Harness.ProjectCacheSeedPltTest do
  use ExUnit.Case, async: true

  alias Harness.GitFixture
  alias Harness.ProjectCache
  alias Harness.ProjectFixture
  alias Harness.Worktree

  @tag timeout: 180_000
  test "application-containing PLT is relocated, updated and still rejects a changed invalid contract" do
    repo = GitFixture.init_repo()
    base = GitFixture.tmp_base()
    cache = GitFixture.tmp_base()
    File.mkdir_p!(Path.join(repo, "lib"))
    File.mkdir_p!(Path.join(repo, "vendor/dep/lib"))
    File.write!(Path.join(repo, ".gitignore"), "_build/\n")

    File.write!(Path.join(repo, "mix.exs"), """
    defmodule SeedApp.MixProject do
      use Mix.Project
      def project, do: [app: :seed_app, version: "0.1.0", deps: [{:seed_dep, path: "vendor/dep"}]]
    end
    """)

    File.write!(Path.join(repo, "vendor/dep/mix.exs"), """
    defmodule SeedDep.MixProject do
      use Mix.Project
      def project, do: [app: :seed_dep, version: "0.1.0"]
    end
    """)

    File.write!(Path.join(repo, "vendor/dep/lib/dep.ex"), """
    defmodule SeedDep do
      @spec increment(integer()) :: integer()
      def increment(value), do: value + 1
    end
    """)

    write_app(repo, "SeedDep.increment(41)")
    GitFixture.git!(repo, ["add", ".gitignore", "mix.exs", "vendor", "lib"])
    GitFixture.git!(repo, ["commit", "-qm", "PLT seed fixture"])
    helper = Application.app_dir(:harness, "priv/cache/relocate_plt.exs")
    elixir_ebin = :elixir |> :code.lib_dir() |> List.to_string() |> Path.join("ebin")
    env = %{"ERL_FLAGS" => "+S 2:2", "MIX_ENV" => "dev"}

    seed = %{
      "commands" => [
        "mix compile",
        "dialyzer -pa '#{elixir_ebin}' --build_plt --output_plt _build/project.plt _build/dev/lib/seed_dep/ebin/*.beam _build/dev/lib/seed_app/ebin/*.beam --apps erts kernel stdlib compiler crypto parsetools syntax_tools"
      ],
      "paths" => ["_build"],
      "inputs" => ["mix.exs", "vendor"],
      "identity_commands" => ["elixir --version", "dialyzer --version"],
      "restore_commands" => ["elixir '#{helper}' _build/project.plt"],
      "env" => env
    }

    recipe =
      seed
      |> Map.put("inputs", ["."])
      |> Map.put("seed", seed)
      |> Map.put("commands", [
        "mix compile --force",
        "dialyzer -pa '#{elixir_ebin}' --check_plt --plt _build/project.plt"
      ])

    project = ProjectFixture.from_repo(repo)
    {:ok, first} = Worktree.create(project, base_dir: base)
    assert {:ok, cold} = ProjectCache.prepare(first, recipe, cache_root: cache)
    assert cold.seed["state"] == "built"

    write_app(repo, "SeedDep.increment(42)")
    commit_app(repo)
    {:ok, second} = Worktree.create(project, base_dir: base)
    assert first.base_sha != second.base_sha
    assert {:ok, warm} = ProjectCache.prepare(second, recipe, cache_root: cache)
    assert cold.seed["key"] == warm.seed["key"]
    assert warm.seed["state"] == "hit"
    assert cold.key != warm.key

    for wt <- [first, second] do
      {output, status} = run("mix", ["compile", "--warnings-as-errors"], wt.path, env)
      assert status == 0, output

      {output, status} =
        run("dialyzer", ["--plt", "_build/project.plt", "_build/dev/lib/seed_app/ebin/Elixir.SeedApp.beam"], wt.path, env)

      assert status == 0, output
      {:ok, info} = :dialyzer.plt_info(String.to_charlist(Path.join(wt.path, "_build/project.plt")))
      assert String.to_charlist(Path.join(wt.path, "_build/dev/lib/seed_app/ebin/Elixir.SeedApp.beam")) in info[:files]
    end

    {output, 0} =
      run(
        "elixir",
        ["-pa", "_build/dev/lib/seed_app/ebin", "-pa", "_build/dev/lib/seed_dep/ebin", "-e", "IO.puts(SeedApp.answer())"],
        second.path,
        env
      )

    assert String.trim(output) == "43"

    write_app(repo, ~s("wrong"))
    commit_app(repo)
    {:ok, invalid} = Worktree.create(project, base_dir: base)
    assert {:ok, prepared} = ProjectCache.prepare(invalid, recipe, cache_root: cache)
    assert prepared.seed["state"] == "hit"

    {output, status} =
      run(
        "dialyzer",
        ["--plt", "_build/project.plt", "_build/dev/lib/seed_app/ebin/Elixir.SeedApp.beam"],
        invalid.path,
        env
      )

    assert status == 2, output
    assert output =~ "Invalid type specification"

    write_app(repo, "missing_function()")
    commit_app(repo)
    {:ok, broken} = Worktree.create(project, base_dir: base)

    assert {:error, {:preparation_command, 1, {:command_exit, 1, output}}} =
             ProjectCache.prepare(broken, recipe, cache_root: cache)

    assert output =~ "undefined function missing_function/0"
    refute File.exists?(Path.join(broken.path, "_build"))
    assert Path.wildcard(Path.join(cache, "*.building-*")) == []
  end

  defp write_app(repo, expression) do
    File.write!(Path.join(repo, "lib/app.ex"), """
    defmodule SeedApp do
      @spec answer() :: integer()
      def answer, do: #{expression}
    end
    """)
  end

  defp commit_app(repo) do
    GitFixture.git!(repo, ["add", "lib/app.ex"])
    GitFixture.git!(repo, ["commit", "-qm", "application revision"])
  end

  defp run("dialyzer", args, path, env) do
    elixir_ebin = :elixir |> :code.lib_dir() |> List.to_string() |> Path.join("ebin")
    System.cmd("dialyzer", ["-pa", elixir_ebin | args], cd: path, env: Map.to_list(env), stderr_to_stdout: true)
  end

  defp run(command, args, path, env),
    do: System.cmd(command, args, cd: path, env: Map.to_list(env), stderr_to_stdout: true)
end
