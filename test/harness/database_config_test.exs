defmodule Harness.DatabaseConfigTest do
  use ExUnit.Case, async: false

  @variables ~w(HARNESS_DATABASE_URL DATABASE_URL HARNESS_DB_NAME HARNESS_DB_USER
                HARNESS_DB_HOST HARNESS_DB_PASSWORD PGHOST PGUSER PGPASSWORD PGPORT USER)

  setup do
    previous = Map.new(@variables, &{&1, System.get_env(&1)})
    Enum.each(@variables, &System.delete_env/1)
    on_exit(fn -> System.put_env(previous) end)
    :ok
  end

  test "local defaults discover an available socket for the OS user" do
    System.put_env("USER", "laptop_user")
    config = database_config()
    assert config[:database] == "harness_dev"
    assert config[:username] == "laptop_user"
    refute Keyword.has_key?(config, :password)

    sockets =
      Enum.filter(["/var/run/postgresql", "/tmp"], fn dir ->
        File.exists?(Path.join(dir, ".s.PGSQL.5432"))
      end)

    case sockets do
      [] -> assert config[:hostname] == "localhost"
      [socket | _] -> assert config[:socket_dir] == socket
    end
  end

  test "explicit TCP settings keep laptop and remote connections on TCP" do
    System.put_env(%{"HARNESS_DB_HOST" => "localhost", "HARNESS_DB_PASSWORD" => "example"})
    config = database_config()
    assert config[:hostname] == "localhost"
    assert config[:password] == "example"
    refute Keyword.has_key?(config, :socket_dir)
  end

  test "password alone retains the localhost TCP default" do
    System.put_env("PGPASSWORD", "example")
    config = database_config()
    assert config[:hostname] == "localhost"
    assert config[:password] == "example"
    refute Keyword.has_key?(config, :socket_dir)
  end

  test "standard Postgres variables support custom socket paths and ports" do
    System.put_env(%{"PGHOST" => "/tmp/laptop-postgres", "PGUSER" => "alice", "PGPORT" => "5544"})
    config = database_config()
    assert config[:socket_dir] == "/tmp/laptop-postgres"
    assert config[:username] == "alice"
    assert config[:port] == 5544
  end

  test "Harness overrides standard Postgres variables" do
    System.put_env(%{
      "HARNESS_DB_HOST" => "db.example",
      "PGHOST" => "/tmp",
      "HARNESS_DB_USER" => "harness",
      "PGUSER" => "alice",
      "HARNESS_DB_PASSWORD" => "harness-example",
      "PGPASSWORD" => "pg-example",
      "HARNESS_DB_NAME" => "custom"
    })

    config = database_config()
    assert config[:hostname] == "db.example"
    assert config[:username] == "harness"
    assert config[:password] == "harness-example"
    assert config[:database] == "custom"
    refute Keyword.has_key?(config, :socket_dir)
  end

  test "database URLs retain precedence over individual settings" do
    url = "ecto://alice:example@localhost/laptop"
    System.put_env(%{"DATABASE_URL" => url, "PGPORT" => "invalid", "PGHOST" => "/tmp"})
    assert database_config() == [url: url]
    harness_url = "ecto://harness:example@db.example/harness"
    System.put_env("HARNESS_DATABASE_URL", harness_url)
    assert database_config() == [url: harness_url]
  end

  test "missing OS user defaults to postgres and invalid ports fail loudly" do
    assert database_config()[:username] == "postgres"
    System.put_env("PGPORT", "invalid")
    assert_raise ArgumentError, fn -> database_config() end
  end

  defp database_config do
    "../../config/runtime.exs"
    |> Path.expand(__DIR__)
    |> Config.Reader.read!(env: :dev, target: :host)
    |> Keyword.fetch!(:harness)
    |> Keyword.fetch!(Harness.Repo)
  end
end
