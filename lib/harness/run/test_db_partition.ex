defmodule Harness.Run.TestDbPartition do
  @moduledoc false

  alias Ecto.Adapters.Postgres

  @doc "Drops Mix.Ecto repos whose resolved database names end with `partition`."
  @spec run!(String.t()) :: :ok
  def run!(partition) when is_binary(partition) do
    Mix.env() == :test || Mix.raise("MIX_ENV=test required")

    Enum.each(Mix.Ecto.parse_repo([]), fn repo_mod ->
      repo = Mix.Ecto.ensure_repo(repo_mod, [])

      case drop_config(repo.config(), partition) do
        :ok -> :ok
        {:error, reason} -> Mix.raise(format_error(reason))
      end
    end)

    :ok
  end

  @doc "Guarded drop of one already-resolved repo config. Never forces a drop."
  @spec drop_config(keyword(), String.t()) :: :ok | {:error, term()}
  def drop_config(config, partition) when is_list(config) and is_binary(partition) do
    database = config[:database]

    with :ok <- validate_partition(partition),
         :ok <- assert_partitioned(database, partition) do
      drop_idle(config, database)
    end
  end

  @doc false
  @spec validate_partition(String.t()) :: :ok | {:error, {:invalid_partition, String.t()}}
  def validate_partition(partition) when is_binary(partition) do
    if Regex.match?(~r/^_h_[A-Za-z0-9_]{1,60}$/, partition) do
      :ok
    else
      {:error, {:invalid_partition, partition}}
    end
  end

  @spec assert_partitioned(term(), String.t()) :: :ok | {:error, {:unpartitioned, term()}}
  defp assert_partitioned(database, partition) when is_binary(database) do
    if database != partition and String.ends_with?(database, partition) do
      :ok
    else
      {:error, {:unpartitioned, database}}
    end
  end

  defp assert_partitioned(database, _partition), do: {:error, {:unpartitioned, database}}

  @spec drop_idle(keyword(), String.t()) :: :ok | {:error, term()}
  defp drop_idle(config, database) do
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)

    # Never FORCE / terminate other sessions — Postgres refuses DROP DATABASE
    # while the name is in use, and that refusal is reported as evidence.
    config = config |> Keyword.put(:force, false) |> Keyword.put(:force_drop, false)

    case Postgres.storage_down(config) do
      :ok -> :ok
      {:error, :already_down} -> :ok
      {:error, reason} -> classify_drop_error(database, reason)
    end
  rescue
    error in Postgrex.Error -> classify_drop_error(database, Exception.message(error))
    error in DBConnection.ConnectionError -> {:error, {:drop_failed, Exception.message(error)}}
  end

  @spec classify_drop_error(String.t(), term()) :: {:error, term()}
  defp classify_drop_error(database, reason) do
    text = drop_error_text(reason)

    if session_block?(text) do
      {:error, {:active_sessions, database, text}}
    else
      {:error, {:drop_failed, reason}}
    end
  end

  @spec drop_error_text(term()) :: String.t()
  defp drop_error_text(reason) when is_binary(reason), do: reason
  defp drop_error_text(reason), do: inspect(reason)

  @spec session_block?(String.t()) :: boolean()
  defp session_block?(text) do
    String.contains?(text, "being accessed by other users") or String.contains?(text, "55006")
  end

  @spec format_error(term()) :: String.t()
  defp format_error({:unpartitioned, database}), do: "refusing drop of unpartitioned database #{inspect(database)}"

  defp format_error({:active_sessions, database, evidence}), do: "active sessions on #{database}: #{evidence}"

  defp format_error({:invalid_partition, partition}), do: "invalid partition #{inspect(partition)}"
  defp format_error({:drop_failed, reason}), do: "drop failed: #{inspect(reason)}"
end
