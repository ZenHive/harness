defmodule Harness.SuiteHealth.PostgresLifecycleTest do
  @moduledoc """
  Two successive real PostgreSQL suite-health checks leave the same scratch
  inventory. The fixture derives its base name from the checkout path so cleanup
  must resolve Mix.Ecto's actual database, not a guessed `{project}_test` name.
  """

  use ExUnit.Case, async: false

  alias Harness.ProjectFixture
  alias Harness.SuiteHealth.Bootstrap
  alias Harness.SuiteHealth.Runner

  @moduletag timeout: 120_000
  @moduletag :tmp_dir

  test "two successive suite-health checks leave the same scratch inventory", %{tmp_dir: dir} do
    {config, conn} = postgres!()
    put_fixture_env!(config)
    fixture!(dir)
    project = ProjectFixture.from_repo(dir, name: "hsh433-lifecycle", languages: [:elixir])

    expected = expected_database(dir)
    before = scratch_names(conn)

    runner = lifecycle_runner()

    assert {:ok, first} = Runner.run_suite(project, dir, "sha-one", runner: runner)
    assert first.passed == true
    refute_database(conn, expected)
    after_first = scratch_names(conn)
    assert after_first == before

    assert {:ok, second} = Runner.run_suite(project, dir, "sha-two", runner: runner)
    assert second.passed == true
    refute_database(conn, expected)
    assert scratch_names(conn) == before

    GenServer.stop(conn)
  end

  @spec lifecycle_runner() :: Bootstrap.runner()
  defp lifecycle_runner do
    fn
      "mix", ["deps.get" | _], _cwd, _env ->
        {"", 0}

      "mix", ["ecto.create" | _], cwd, env ->
        Bootstrap.default_runner("mix", ["ecto.create", "--quiet"], cwd, env)

      "mix", ["ecto.migrate" | _], cwd, env ->
        Bootstrap.default_runner("mix", ["ecto.migrate", "--quiet"], cwd, env)

      "mix", ["test.json" | _], _cwd, _env ->
        {~s({"summary":{"failed":0,"result":"passed"},"tests":[]}), 0}

      cmd, args, _cwd, _env ->
        flunk("unexpected #{cmd} #{inspect(args)}")
    end
  end

  @spec fixture!(String.t()) :: :ok
  defp fixture!(dir) do
    for path <- ["config", "lib", "priv/repo/migrations"], do: File.mkdir_p!(Path.join(dir, path))

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule HshProbe.MixProject do
      use Mix.Project

      def project do
        [
          app: :hsh_probe,
          version: "0.1.0",
          elixir: "~> 1.18",
          deps_path: #{inspect(Path.expand("deps"))},
          lockfile: #{inspect(Path.expand("mix.lock"))},
          deps: [{:ecto_sql, "~> 3.13"}, {:postgrex, ">= 0.0.0"}]
        ]
      end
    end
    """)

    File.write!(Path.join(dir, "config/config.exs"), """
    import Config
    import_config "\#{config_env()}.exs"
    """)

    File.write!(Path.join(dir, "config/dev.exs"), "import Config\n")

    File.write!(Path.join(dir, "config/test.exs"), """
    import Config

    hash =
      :crypto.hash(:sha256, File.cwd!())
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    repo = [
      username: System.get_env("FIXTURE_USER") || System.get_env("USER") || "postgres",
      database: "hsh433" <> hash <> "_test" <> System.get_env("MIX_TEST_PARTITION", ""),
      port: String.to_integer(System.get_env("FIXTURE_PORT") || "5432")
    ]

    repo =
      case System.get_env("FIXTURE_SOCKET") do
        nil -> Keyword.put(repo, :hostname, System.get_env("FIXTURE_HOST") || "localhost")
        socket -> Keyword.put(repo, :socket_dir, socket)
      end

    repo =
      case System.get_env("FIXTURE_PASSWORD") do
        nil -> repo
        password -> Keyword.put(repo, :password, password)
      end

    config :hsh_probe, ecto_repos: [HshProbe.Repo]
    config :hsh_probe, HshProbe.Repo, repo
    """)

    File.write!(Path.join(dir, "lib/repo.ex"), """
    defmodule HshProbe.Repo do
      use Ecto.Repo, otp_app: :hsh_probe, adapter: Ecto.Adapters.Postgres
    end
    """)

    :ok
  end

  @spec expected_database(String.t()) :: String.t()
  defp expected_database(dir) do
    hash =
      :sha256
      |> :crypto.hash(Path.expand(dir))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    "hsh433#{hash}_test_h_suite_health"
  end

  @spec postgres!() :: {keyword(), pid()}
  defp postgres! do
    config = Harness.PostgresConn.config!()
    {:ok, conn} = Postgrex.start_link(Keyword.put(config, :database, "postgres"))
    {config, conn}
  end

  @spec put_fixture_env!(keyword()) :: :ok
  defp put_fixture_env!(config) do
    previous = snapshot_fixture_env()
    clear_fixture_env()
    apply_fixture_env(config)

    on_exit(fn -> restore_fixture_env(previous) end)
    :ok
  end

  @spec snapshot_fixture_env() :: %{optional(String.t()) => String.t() | nil}
  defp snapshot_fixture_env do
    Map.new(~w(FIXTURE_SOCKET FIXTURE_HOST FIXTURE_PORT FIXTURE_USER FIXTURE_PASSWORD), &{&1, System.get_env(&1)})
  end

  @spec clear_fixture_env() :: :ok
  defp clear_fixture_env do
    Enum.each(~w(FIXTURE_SOCKET FIXTURE_HOST FIXTURE_PASSWORD), &System.delete_env/1)
  end

  @spec apply_fixture_env(keyword()) :: :ok
  defp apply_fixture_env(config) do
    put_endpoint_env(config)
    System.put_env("FIXTURE_PORT", Integer.to_string(config[:port] || 5432))
    System.put_env("FIXTURE_USER", config[:username] || System.get_env("USER") || "postgres")
    put_password_env(config[:password])
  end

  @spec put_endpoint_env(keyword()) :: :ok
  defp put_endpoint_env(config) do
    case config[:socket_dir] || config[:socket] do
      nil -> System.put_env("FIXTURE_HOST", config[:hostname] || "localhost")
      socket -> System.put_env("FIXTURE_SOCKET", socket)
    end
  end

  @spec put_password_env(String.t() | nil) :: :ok
  defp put_password_env(nil), do: :ok
  defp put_password_env(password), do: System.put_env("FIXTURE_PASSWORD", password)

  @spec restore_fixture_env(%{optional(String.t()) => String.t() | nil}) :: :ok
  defp restore_fixture_env(previous) do
    Enum.each(previous, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  @spec scratch_names(pid()) :: [String.t()]
  defp scratch_names(conn) do
    %{rows: rows} =
      Postgrex.query!(conn, "SELECT datname FROM pg_database WHERE datname LIKE 'hsh433%' ORDER BY 1", [])

    Enum.map(rows, &hd/1)
  end

  @spec database_exists?(pid(), String.t()) :: boolean()
  defp database_exists?(conn, name) do
    %{rows: rows} = Postgrex.query!(conn, "SELECT 1 FROM pg_database WHERE datname = $1", [name])
    rows != []
  end

  @spec refute_database(pid(), String.t()) :: :ok
  defp refute_database(conn, name) do
    refute database_exists?(conn, name), "expected #{name} to be dropped"
    :ok
  end
end
