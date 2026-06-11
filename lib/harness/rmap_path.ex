defmodule Harness.RmapPath do
  @moduledoc """
  Makes the owned `rmap` CLI reachable to spawned agents.

  Harness does not interpret discovery tasks. It only ensures the CLI an agent
  may choose to run is on `PATH` inside isolated worktrees.
  """

  @path_key "PATH"
  @rmap "rmap"

  @doc false
  @spec ensure_agent_env(%{optional(String.t()) => String.t() | false}) :: %{optional(String.t()) => String.t() | false}
  def ensure_agent_env(env) when is_map(env) do
    path = env |> Map.get(@path_key) |> effective_path()
    Map.put(env, @path_key, prepend_candidate_dirs(path))
  end

  @spec effective_path(String.t() | false | nil) :: String.t()
  defp effective_path(false), do: ""
  defp effective_path(path) when is_binary(path), do: path
  defp effective_path(_path), do: System.get_env(@path_key, "")

  @spec prepend_candidate_dirs(String.t()) :: String.t()
  defp prepend_candidate_dirs(path) do
    parts = String.split(path, ":", trim: true)
    extra = Enum.reject(rmap_dirs(), &(&1 in parts))

    (extra ++ parts)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(":")
  end

  @spec rmap_dirs() :: [String.t()]
  defp rmap_dirs do
    :harness
    |> Application.get_env(:rmap_path_dirs, [])
    |> Kernel.++(default_dirs())
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
    |> Enum.filter(&File.regular?(Path.join(&1, @rmap)))
  end

  @spec default_dirs() :: [String.t()]
  defp default_dirs do
    [
      "~/.cargo/bin",
      "../rmap/target/release",
      "../../rmap/target/release",
      "/opt/homebrew/bin",
      "/usr/local/bin"
    ]
  end
end
