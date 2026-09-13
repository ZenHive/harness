defmodule Harness.Run.TestDbTemplate do
  @moduledoc """
  Consumes an operator-prepared PostgreSQL test template for one Ecto repo.

  The template must be frozen, privately owned by the test role, and marked
  `harness:test-template:v1`. See `docs/test-db-templates.md`.
  """

  @keys ~w(database extensions repo template)
  @connection_keys ~w(hostname port username password socket_dir socket ssl ssl_opts connect_timeout)a
  @template_marker "harness:test-template:v1"

  @doc "Validates the explicit single-repo template recipe."
  @spec normalize(term()) :: {:ok, map() | nil} | {:error, String.t()}
  def normalize(nil), do: {:ok, nil}

  def normalize(%{"repo" => repo, "database" => database, "template" => template, "extensions" => extensions} = recipe) do
    if Enum.sort(Map.keys(recipe)) == @keys and is_binary(repo) and
         Regex.match?(~r/^[A-Z]\w*(\.[A-Z]\w*)+$/, repo) and
         database_name?(database) and template_name?(template) and extensions_valid?(extensions) do
      {:ok, recipe}
    else
      setup_error(
        "invalid recipe: require one repo, a database ending _test (max 36 bytes), a harness_test_template_ name and nonempty extensions"
      )
    end
  end

  def normalize(_), do: setup_error("invalid recipe: require repo, database, template and extensions")

  @doc "Returns a bounded partition derived from the entire run identifier."
  @spec partition(String.t()) :: String.t()
  def partition(run_id), do: "_h_" <> binary_part(Base.encode16(:crypto.hash(:sha256, run_id), case: :lower), 0, 24)

  @doc "Creates only the explicitly configured partition and verifies its extensions."
  @spec prepare(map(), keyword(), String.t()) :: :ok | {:error, String.t()}
  def prepare(recipe, config, run_id) do
    with :ok <- validate_target(recipe, config, run_id),
         :ok <- connection(config, "postgres", &clone(&1, recipe, config[:database], run_id)) do
      case connection(config, config[:database], &extensions(&1, recipe["extensions"])) do
        :ok ->
          :ok

        {:error, reason} ->
          cleanup = drop(recipe, config, run_id)
          {:error, reason <> "; failed clone cleanup: " <> inspect(cleanup)}
      end
    end
  end

  @doc "Drops only a partition carrying this run's ownership marker."
  @spec drop(map(), keyword(), String.t()) :: :ok | {:error, String.t()}
  def drop(recipe, config, run_id) do
    with :ok <- validate_target(recipe, config, run_id) do
      expected_marker = "harness:test-run:" <> partition(run_id)

      connection(config, "postgres", &drop_owned(&1, config[:database], expected_marker))
    end
  end

  @spec drop_owned(pid(), String.t(), String.t()) :: :ok | {:error, String.t()}
  defp drop_owned(conn, database, expected_marker) do
    case Postgrex.query!(
           conn,
           """
           SELECT shobj_description(oid, 'pg_database'), datdba = (SELECT oid FROM pg_roles WHERE rolname = current_user), datistemplate
           FROM pg_database WHERE datname = $1
           """,
           [database]
         ).rows do
      [] ->
        :ok

      [[^expected_marker, true, false]] ->
        Postgrex.query!(conn, "DROP DATABASE " <> quote_identifier(database), [])
        :ok

      _ ->
        setup_error("refusing cleanup of #{database}: run ownership marker or database owner differs")
    end
  end

  @doc "Runs inside the consuming worktree after Mix loads its test configuration."
  @spec run!(map(), String.t(), :prepare | :drop) :: :ok
  def run!(recipe, run_id, action) do
    {:ok, _} = Application.ensure_all_started(:postgrex)

    with true <- Mix.env() == :test,
         [repo] <- Mix.Ecto.parse_repo([]),
         true <- inspect(repo) == recipe["repo"],
         repo = Mix.Ecto.ensure_repo(repo, []),
         true <- repo.__adapter__() == Ecto.Adapters.Postgres,
         :ok <- apply(__MODULE__, action, [recipe, repo.config(), run_id]) do
      :ok
    else
      {:error, reason} ->
        Mix.raise(reason)

      _ ->
        Mix.raise(
          "test database setup: require MIX_ENV=test and exactly the configured PostgreSQL Ecto repo; see docs/test-db-templates.md"
        )
    end
  end

  @spec validate_target(map(), keyword(), String.t()) :: :ok | {:error, String.t()}
  defp validate_target(recipe, config, run_id) do
    with {:ok, recipe} when is_map(recipe) <- normalize(recipe) do
      expected = recipe["database"] <> partition(run_id)

      if config[:database] == expected,
        do: :ok,
        else:
          setup_error(
            "repo database must equal partition #{expected}; verify the project's isolation environment configuration"
          )
    end
  end

  @spec database_name?(term()) :: boolean()
  defp database_name?(name), do: identifier?(name) and String.ends_with?(name, "_test") and byte_size(name) <= 36

  @spec template_name?(term()) :: boolean()
  defp template_name?(name), do: identifier?(name) and String.starts_with?(name, "harness_test_template_")

  @spec extensions_valid?(term()) :: boolean()
  defp extensions_valid?(extensions),
    do: is_list(extensions) and extensions != [] and Enum.all?(extensions, &identifier?/1)

  @spec clone(pid(), map(), String.t(), String.t()) :: :ok | {:error, String.t()}
  defp clone(conn, recipe, database, run_id) do
    with :ok <- privileges(conn),
         :ok <- prepared_template(conn, recipe["template"]) do
      Postgrex.query!(
        conn,
        "CREATE DATABASE #{quote_identifier(database)} TEMPLATE #{quote_identifier(recipe["template"])}",
        []
      )

      marker = "harness:test-run:" <> partition(run_id)
      Postgrex.query!(conn, "COMMENT ON DATABASE #{quote_identifier(database)} IS '#{marker}'", [])
      :ok
    end
  end

  @spec privileges(pid()) :: :ok | {:error, String.t()}
  defp privileges(conn) do
    case Postgrex.query!(conn, "SELECT rolcreatedb FROM pg_roles WHERE rolname = current_user", []).rows do
      [[true]] ->
        :ok

      _ ->
        setup_error(
          "test role requires operator-provided CREATEDB and ownership of the dedicated template; harness grants no privileges"
        )
    end
  end

  @spec prepared_template(pid(), String.t()) :: :ok | {:error, String.t()}
  defp prepared_template(conn, template) do
    case Postgrex.query!(
           conn,
           """
           SELECT datallowconn, datistemplate, datdba = (SELECT oid FROM pg_roles WHERE rolname = current_user),
                  shobj_description(oid, 'pg_database')
           FROM pg_database WHERE datname = $1
           """,
           [template]
         ).rows do
      [[false, false, true, @template_marker]] ->
        :ok

      _ ->
        setup_error(
          "template #{template} is missing or not operator-prepared: require ownership by the test role, ALLOW_CONNECTIONS false, IS_TEMPLATE false and COMMENT '#{@template_marker}'"
        )
    end
  end

  @spec extensions(pid(), [String.t()]) :: :ok | {:error, String.t()}
  defp extensions(conn, required) do
    installed = conn |> Postgrex.query!("SELECT extname FROM pg_extension", []) |> Map.fetch!(:rows) |> List.flatten()

    case required -- installed do
      [] ->
        :ok

      missing ->
        setup_error(
          "missing extensions #{Enum.join(missing, ", ")}; operator must prepare and freeze a replacement template with the required server extensions"
        )
    end
  end

  @spec connection(keyword(), String.t(), (pid() -> :ok | {:error, String.t()})) :: :ok | {:error, String.t()}
  defp connection(config, database, fun) do
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)

    task =
      Task.Supervisor.async_nolink(Ecto.Adapters.SQL.StorageSupervisor, fn ->
        query_connection(config, database, fun)
      end)

    case Task.yield(task, 30_000) || Task.shutdown(task) do
      {:ok, result} -> result
      {:exit, reason} -> setup_error("PostgreSQL connection failed for #{database}: #{Exception.format_exit(reason)}")
      nil -> setup_error("PostgreSQL operation timed out for #{database} after 30 seconds")
    end
  end

  @spec query_connection(keyword(), String.t(), (pid() -> :ok | {:error, String.t()})) :: :ok | {:error, String.t()}
  defp query_connection(config, database, fun) do
    opts =
      config
      |> Keyword.take(@connection_keys)
      |> Keyword.merge(database: database, backoff_type: :stop, max_restarts: 0)

    case Postgrex.start_link(opts) do
      {:ok, conn} ->
        try do
          fun.(conn)
        after
          GenServer.stop(conn)
        end

      {:error, reason} ->
        setup_error("PostgreSQL connection failed: #{Exception.message(reason)}")
    end
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] -> setup_error(Exception.message(error))
  end

  @spec identifier?(term()) :: boolean()
  defp identifier?(value), do: is_binary(value) and byte_size(value) <= 63 and Regex.match?(~r/^[a-z][a-z0-9_]*$/, value)

  @spec quote_identifier(String.t()) :: String.t()
  defp quote_identifier(value), do: ~s("#{value}")

  @spec setup_error(String.t()) :: {:error, String.t()}
  defp setup_error(reason), do: {:error, "test database setup: #{reason}; see docs/test-db-templates.md"}
end
