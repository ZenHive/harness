defmodule Harness.PostgresConn do
  @moduledoc false

  import ExUnit.Assertions

  @doc "Discrete Postgrex settings from Harness.Repo, including ecto:// URLs."
  @spec config!() :: keyword()
  def config! do
    case Application.get_env(:harness, Harness.Repo) do
      nil ->
        flunk("Harness.Repo is not configured; cannot exercise live PostgreSQL.")

      config ->
        connection_config(config)
    end
  end

  @spec connection_config(keyword()) :: keyword()
  defp connection_config(config) do
    discrete =
      config
      |> Keyword.take([:hostname, :port, :username, :password, :socket_dir, :socket])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    cond do
      discrete[:hostname] || discrete[:socket_dir] || discrete[:socket] ->
        discrete
        |> Keyword.put_new(:port, 5432)
        |> Keyword.put_new(:username, System.get_env("USER") || "postgres")

      is_binary(config[:url]) ->
        parse_url(config[:url])

      true ->
        flunk("Harness.Repo has neither discrete connection settings nor a URL.")
    end
  end

  @spec parse_url(String.t()) :: keyword()
  defp parse_url(url) do
    uri = URI.parse(url)
    query = URI.decode_query(uri.query || "")
    {username, password} = userinfo(uri.userinfo)

    []
    |> maybe_put(:username, username || System.get_env("USER") || "postgres")
    |> maybe_put(:password, password)
    |> Keyword.put(:port, uri.port || 5432)
    |> endpoint(uri, query)
  end

  @spec userinfo(String.t() | nil) :: {String.t() | nil, String.t() | nil}
  defp userinfo(nil), do: {nil, nil}

  defp userinfo(info) do
    case String.split(info, ":", parts: 2) do
      [user] -> {user, nil}
      [user, ""] -> {user, nil}
      [user, pass] -> {user, pass}
    end
  end

  @spec endpoint(keyword(), URI.t(), map()) :: keyword()
  defp endpoint(config, uri, query) do
    case query["socket_dir"] do
      socket when is_binary(socket) and socket != "" ->
        Keyword.put(config, :socket_dir, socket)

      _ ->
        endpoint_from_host(config, uri)
    end
  end

  @spec endpoint_from_host(keyword(), URI.t()) :: keyword()
  defp endpoint_from_host(config, uri) do
    host = uri.host

    cond do
      is_binary(host) and String.starts_with?(host, "/") -> Keyword.put(config, :socket_dir, host)
      is_binary(host) and host != "" -> Keyword.put(config, :hostname, host)
      true -> endpoint_from_pghost(config)
    end
  end

  @spec endpoint_from_pghost(keyword()) :: keyword()
  defp endpoint_from_pghost(config) do
    case System.get_env("PGHOST") do
      socket when is_binary(socket) and socket != "" -> Keyword.put(config, :socket_dir, socket)
      _ -> Keyword.put(config, :hostname, "localhost")
    end
  end

  @spec maybe_put(keyword(), atom(), String.t() | nil) :: keyword()
  defp maybe_put(config, _key, nil), do: config
  defp maybe_put(config, key, value), do: Keyword.put(config, key, value)
end
