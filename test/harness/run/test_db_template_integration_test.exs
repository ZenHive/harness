defmodule Harness.Run.TestDbTemplateIntegrationTest do
  use ExUnit.Case, async: true

  alias Harness.Project
  alias Harness.Run.TestDbIsolation
  alias Harness.Run.TestDbTemplate

  @moduletag :integration

  setup do
    socket =
      System.get_env("HARNESS_TEMPLATE_TEST_SOCKET") ||
        flunk(
          "Set HARNESS_TEMPLATE_TEST_SOCKET to an operator-prepared PostgreSQL test cluster socket; see docs/test-db-templates.md (live test setup)."
        )

    config = [socket_dir: socket, port: 55_422, username: "template_runner", database: "postgres"]
    run_id = "template-test-#{System.unique_integer([:positive])}"

    recipe = %{
      "repo" => "Fixture.Repo",
      "database" => "fixture_test",
      "template" => "harness_test_template_probe",
      "extensions" => ["vector", "postgis"]
    }

    database = recipe["database"] <> TestDbTemplate.partition(run_id)
    config = Keyword.put(config, :database, database)
    on_exit(fn -> assert :ok = TestDbTemplate.drop(recipe, config, run_id) end)
    %{recipe: recipe, config: config, run_id: run_id}
  end

  test "concurrent clones retain extensions, migrate independently and clean up only their own database", ctx do
    other_id = ctx.run_id <> "-other"
    other_config = Keyword.put(ctx.config, :database, "fixture_test" <> TestDbTemplate.partition(other_id))
    on_exit(fn -> assert :ok = TestDbTemplate.drop(ctx.recipe, other_config, other_id) end)

    tasks =
      for {config, id} <- [{ctx.config, ctx.run_id}, {other_config, other_id}] do
        Task.async(fn -> TestDbTemplate.prepare(ctx.recipe, config, id) end)
      end

    assert Enum.map(tasks, &Task.await(&1, 30_000)) == [:ok, :ok]
    assert ctx.config[:database] != other_config[:database]

    for config <- [ctx.config, other_config] do
      {:ok, conn} = Postgrex.start_link(config)

      assert %{rows: [["[1,2,3]", "POINT(1 2)"]]} =
               Postgrex.query!(conn, "SELECT '[1,2,3]'::vector::text, ST_AsText(ST_Point(1,2))", [])

      assert %{num_rows: 0} = Postgrex.query!(conn, "CREATE TABLE migration_check (id integer PRIMARY KEY)", [])
      assert %{num_rows: 1} = Postgrex.query!(conn, "INSERT INTO migration_check VALUES (42)", [])
      GenServer.stop(conn)
    end

    assert :ok = TestDbTemplate.drop(ctx.recipe, ctx.config, ctx.run_id)
    {:ok, survivor} = Postgrex.start_link(other_config)
    assert %{rows: [[42]]} = Postgrex.query!(survivor, "SELECT id FROM migration_check", [])
    GenServer.stop(survivor)
  end

  test "missing template fails with its exact name and setup evidence", ctx do
    recipe = %{ctx.recipe | "template" => "harness_test_template_missing"}
    assert {:error, evidence} = TestDbTemplate.prepare(recipe, ctx.config, ctx.run_id)
    assert evidence =~ "harness_test_template_missing"
    assert evidence =~ "operator"
    refute_database(ctx.config, ctx.config[:database])
  end

  test "missing extensions fail and remove the failed clone", ctx do
    recipe = %{ctx.recipe | "extensions" => ["harness_missing_extension"]}
    assert {:error, evidence} = TestDbTemplate.prepare(recipe, ctx.config, ctx.run_id)
    assert evidence =~ "harness_missing_extension"
    assert evidence =~ "extension"
    assert :ok = TestDbTemplate.prepare(ctx.recipe, ctx.config, ctx.run_id)
  end

  test "insufficient privileges fail explicitly without granting privileges", ctx do
    config = Keyword.put(ctx.config, :username, "template_denied")
    assert {:error, evidence} = TestDbTemplate.prepare(ctx.recipe, config, ctx.run_id)
    assert evidence =~ "CREATEDB"
    {:ok, conn} = Postgrex.start_link(Keyword.put(ctx.config, :database, "postgres"))

    assert %{rows: [[false]]} =
             Postgrex.query!(conn, "SELECT rolcreatedb FROM pg_roles WHERE rolname = 'template_denied'", [])

    GenServer.stop(conn)
    refute_database(ctx.config, ctx.config[:database])
  end

  test "refuses a repo pointing at an unpartitioned database", ctx do
    config = Keyword.put(ctx.config, :database, "fixture_test")
    assert {:error, evidence} = TestDbTemplate.prepare(ctx.recipe, config, ctx.run_id)
    assert evidence =~ "partition"
    refute_database(ctx.config, "fixture_test")
    refute_database(ctx.config, ctx.config[:database])
  end

  test "never reuses an existing database or drops another run's database", ctx do
    assert :ok = TestDbTemplate.prepare(ctx.recipe, ctx.config, ctx.run_id)
    assert {:error, evidence} = TestDbTemplate.prepare(ctx.recipe, ctx.config, ctx.run_id)
    assert evidence =~ "already exists"
    assert {:error, _} = TestDbTemplate.drop(ctx.recipe, ctx.config, ctx.run_id <> "-foreign")
  end

  test "rejects an unmarked or connectable template even with a dedicated name", ctx do
    template = "harness_test_template_" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, conn} = Postgrex.start_link(Keyword.put(ctx.config, :database, "postgres"))
    Postgrex.query!(conn, "CREATE DATABASE #{template} TEMPLATE template0", [])
    recipe = %{ctx.recipe | "template" => template}

    try do
      assert {:error, evidence} = TestDbTemplate.prepare(recipe, ctx.config, ctx.run_id)
      assert evidence =~ "operator-prepared"
      Postgrex.query!(conn, "COMMENT ON DATABASE #{template} IS 'harness:test-template:v1'", [])
      assert {:error, evidence} = TestDbTemplate.prepare(recipe, ctx.config, ctx.run_id)
      assert evidence =~ "ALLOW_CONNECTIONS false"
    after
      Postgrex.query!(conn, "DROP DATABASE #{template}", [])
      GenServer.stop(conn)
    end
  end

  test "cleanup refuses an altered ownership marker", ctx do
    assert :ok = TestDbTemplate.prepare(ctx.recipe, ctx.config, ctx.run_id)
    {:ok, conn} = Postgrex.start_link(Keyword.put(ctx.config, :database, "postgres"))
    Postgrex.query!(conn, "COMMENT ON DATABASE #{ctx.config[:database]} IS 'foreign'", [])
    assert {:error, evidence} = TestDbTemplate.drop(ctx.recipe, ctx.config, ctx.run_id)
    assert evidence =~ "refusing cleanup"

    Postgrex.query!(
      conn,
      "COMMENT ON DATABASE #{ctx.config[:database]} IS 'harness:test-run:#{TestDbTemplate.partition(ctx.run_id)}'",
      []
    )

    GenServer.stop(conn)
  end

  @tag :tmp_dir
  @tag timeout: 120_000
  test "worktree subprocess provisions Ecto's actual database and project migrations/checks run there", ctx do
    fixture!(ctx.tmp_dir)

    project = %Project{
      name: "fixture",
      source: {:local, ctx.tmp_dir},
      roadmap_path: ctx.tmp_dir,
      languages: [:elixir],
      test_db_template: ctx.recipe
    }

    env = %{
      "FIXTURE_SOCKET" => ctx.config[:socket_dir],
      "MIX_BUILD_PATH" => Path.join(ctx.tmp_dir, "_build"),
      "GH_TOKEN" => false,
      "GITHUB_TOKEN" => false
    }

    assert :ok = TestDbIsolation.prepare(project, ctx.tmp_dir, ctx.run_id, env)

    command_env =
      env
      |> Map.merge(TestDbIsolation.env(project, ctx.run_id))
      |> Map.put("MIX_ENV", "test")
      |> Enum.map(fn
        {key, false} -> {key, nil}
        pair -> pair
      end)

    {output, status} =
      System.cmd("mix", ["do", "ecto.migrate", "+", "test"], cd: ctx.tmp_dir, env: command_env, stderr_to_stdout: true)

    assert status == 0, output
    {:ok, conn} = Postgrex.start_link(ctx.config)

    assert %{rows: [["[1,2,3]", "POINT(1 2)"]]} =
             Postgrex.query!(conn, "SELECT embedding::text, ST_AsText(location) FROM probe", [])

    GenServer.stop(conn)
    assert :ok = TestDbIsolation.teardown(project, ctx.tmp_dir, ctx.run_id, env)
    {:ok, maintenance} = Postgrex.start_link(Keyword.put(ctx.config, :database, "postgres"))

    assert %{rows: []} =
             Postgrex.query!(maintenance, "SELECT datname FROM pg_database WHERE datname = $1", [ctx.config[:database]])

    GenServer.stop(maintenance)

    assert {:error, {:test_db_template, _, evidence}} =
             TestDbIsolation.prepare(project, ctx.tmp_dir, ctx.run_id, Map.put(env, "FIXTURE_BASE", "unpartitioned"))

    assert evidence =~ "repo database must equal partition"
  end

  @spec refute_database(keyword(), String.t()) :: :ok
  defp refute_database(config, name) do
    {:ok, conn} = Postgrex.start_link(Keyword.put(config, :database, "postgres"))

    try do
      assert %{rows: []} = Postgrex.query!(conn, "SELECT 1 FROM pg_database WHERE datname = $1", [name])
      :ok
    after
      GenServer.stop(conn)
    end
  end

  @spec fixture!(String.t()) :: :ok
  defp fixture!(dir) do
    for path <- ["config", "lib", "priv/repo/migrations", "test"], do: File.mkdir_p!(Path.join(dir, path))
    File.cp!("mix.lock", Path.join(dir, "mix.lock"))

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule Fixture.MixProject do
      use Mix.Project
      def project, do: [app: :db_template_fixture, version: "0.1.0", deps_path: #{inspect(Path.expand("deps"))}, deps: [{:ecto_sql, "~> 3.13"}, {:postgrex, ">= 0.0.0"}]]
    end
    """)

    File.write!(Path.join(dir, "config/config.exs"), "import Config\nimport_config \"test.exs\"\n")

    File.write!(Path.join(dir, "config/test.exs"), """
    import Config
    config :db_template_fixture, ecto_repos: [Fixture.Repo]
    config :db_template_fixture, Fixture.Repo,
      socket_dir: System.fetch_env!("FIXTURE_SOCKET"), port: 55422, username: "template_runner",
      database: System.get_env("FIXTURE_BASE", "fixture_test") <> System.get_env("MIX_TEST_PARTITION", "")
    """)

    File.write!(Path.join(dir, "lib/repo.ex"), """
    defmodule Fixture.Repo do
      use Ecto.Repo, otp_app: :db_template_fixture, adapter: Ecto.Adapters.Postgres
    end
    """)

    File.write!(Path.join(dir, "priv/repo/migrations/20260913000000_probe.exs"), """
    defmodule Fixture.Probe do
      use Ecto.Migration
      def change, do: execute("CREATE TABLE probe (embedding vector(3), location geometry(Point,4326))", "DROP TABLE probe")
    end
    """)

    File.write!(Path.join(dir, "test/test_helper.exs"), "ExUnit.start()\n{:ok, _} = Fixture.Repo.start_link()\n")

    File.write!(Path.join(dir, "test/probe_test.exs"), """
    defmodule Fixture.ProbeTest do
      use ExUnit.Case
      test "extension types work after migration" do
        assert %{num_rows: 1} = Ecto.Adapters.SQL.query!(Fixture.Repo, "INSERT INTO probe VALUES ('[1,2,3]', ST_SetSRID(ST_Point(1,2),4326))", [])
        assert %{rows: [[\"[1,2,3]\", \"POINT(1 2)\"]]} = Ecto.Adapters.SQL.query!(Fixture.Repo, "SELECT embedding::text, ST_AsText(location) FROM probe", [])
      end
    end
    """)
  end
end
