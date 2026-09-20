defmodule Harness.Run.TestDbPartitionTest do
  @moduledoc """
  Guarded drop of an explicit partition: refuse shared names, skip active
  sessions, never FORCE.
  """

  use ExUnit.Case, async: false

  alias Harness.Run.TestDbPartition

  test "validate_partition accepts the suite-health suffix and rejects a shared name" do
    assert :ok = TestDbPartition.validate_partition("_h_suite_health")
    assert :ok = TestDbPartition.validate_partition("_h_deadbeef")
    assert {:error, {:invalid_partition, "test"}} = TestDbPartition.validate_partition("test")
    assert {:error, {:invalid_partition, ""}} = TestDbPartition.validate_partition("")
    assert {:error, {:invalid_partition, "_h_"}} = TestDbPartition.validate_partition("_h_")
  end

  test "drop_config refuses an unpartitioned database and leaves it in place" do
    {config, conn} = postgres!()
    database = unique_name("shared")
    Postgrex.query!(conn, ~s(CREATE DATABASE "#{database}"), [])

    try do
      assert {:error, {:unpartitioned, ^database}} =
               TestDbPartition.drop_config(Keyword.put(config, :database, database), "_h_suite_health")

      assert database_exists?(conn, database)
    after
      Postgrex.query!(conn, ~s(DROP DATABASE IF EXISTS "#{database}"), [])
      GenServer.stop(conn)
    end
  end

  test "drop_config skips active sessions and never terminates them" do
    {config, maint} = postgres!()
    database = unique_name("sess")
    Postgrex.query!(maint, ~s(CREATE DATABASE "#{database}"), [])
    {:ok, session} = Postgrex.start_link(Keyword.put(config, :database, database))

    try do
      assert {:error, {:active_sessions, ^database, evidence}} =
               TestDbPartition.drop_config(Keyword.put(config, :database, database), "_h_suite_health")

      assert evidence =~ "being accessed by other users"
      assert database_exists?(maint, database)
      assert %{num_rows: 1} = Postgrex.query!(session, "SELECT 1", [])
    after
      GenServer.stop(session)
      Postgrex.query!(maint, ~s(DROP DATABASE IF EXISTS "#{database}"), [])
      GenServer.stop(maint)
    end
  end

  test "drop_config removes an idle partitioned database" do
    {config, conn} = postgres!()
    database = unique_name("idle")
    Postgrex.query!(conn, ~s(CREATE DATABASE "#{database}"), [])

    try do
      assert :ok = TestDbPartition.drop_config(Keyword.put(config, :database, database), "_h_suite_health")
      refute database_exists?(conn, database)
      assert :ok = TestDbPartition.drop_config(Keyword.put(config, :database, database), "_h_suite_health")
    after
      Postgrex.query(conn, ~s(DROP DATABASE IF EXISTS "#{database}"), [])
      GenServer.stop(conn)
    end
  end

  test "drop_config refuses a non-binary database name" do
    assert {:error, {:unpartitioned, nil}} = TestDbPartition.drop_config([database: nil], "_h_suite_health")
  end

  test "drop_config reports a failed drop without forcing" do
    config = Harness.PostgresConn.config!()
    database = unique_name("idle")

    unreachable =
      config
      |> Keyword.delete(:socket_dir)
      |> Keyword.delete(:socket)
      |> Keyword.put(:hostname, "127.0.0.1")
      |> Keyword.put(:port, 1)
      |> Keyword.put(:connect_timeout, 200)
      |> Keyword.put(:database, database)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:drop_failed, _reason}} = TestDbPartition.drop_config(unreachable, "_h_suite_health")
      end)

    assert log =~ "connection refused"
  end

  test "run! raises on an unpartitioned host repo and on an invalid partition" do
    database = Keyword.get(Harness.Repo.config(), :database)
    refute is_binary(database) and String.ends_with?(database, "_h_suite_health")

    assert_raise Mix.Error, ~r/unpartitioned/, fn ->
      TestDbPartition.run!("_h_suite_health")
    end

    assert_raise Mix.Error, ~r/invalid partition/, fn ->
      TestDbPartition.run!("test")
    end
  end

  @spec postgres!() :: {keyword(), pid()}
  defp postgres! do
    config = Harness.PostgresConn.config!()
    {:ok, conn} = Postgrex.start_link(Keyword.put(config, :database, "postgres"))
    {config, conn}
  end

  @spec unique_name(String.t()) :: String.t()
  defp unique_name("shared"), do: "hsh433shared#{System.unique_integer([:positive])}_test"

  defp unique_name(kind) do
    "hsh433#{kind}#{System.unique_integer([:positive])}_test_h_suite_health"
  end

  @spec database_exists?(pid(), String.t()) :: boolean()
  defp database_exists?(conn, name) do
    %{rows: rows} = Postgrex.query!(conn, "SELECT 1 FROM pg_database WHERE datname = $1", [name])
    rows != []
  end
end
